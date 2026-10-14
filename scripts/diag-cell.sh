#!/bin/bash
# Two warm servers, one cell, CPU attributed per process. For explaining a gap, not
# finding one.
#
# `ab-perf.sh` says *that* two variants differ at a given concurrency. This says *where*
# the request went, in both servers at once, which is the only way to answer a question
# of the form "the same server wins at concurrency 8 and 32 but loses at 16, so what is
# different at 16". A wall-clock number cannot answer that — both servers report their
# own latency and their own rps, and the difference is a difference of the same
# quantity on both sides.
#
# The method is `diag-split.sh`'s, extended to a second server: two snapshots of
# `utime + stime` around a measured `wrk` run, walked up the PPID chain from each
# server's own pid, so a client or one server's work cannot leak into the other's
# column. Two samples are subtracted rather than added, because the counters are
# cumulative since process start.
#
# Why this exists rather than a flag on an existing script: `diag-checksum.sh` compares
# three *volucer* builds and has no RoadRunner path, and `diag-split.sh` measures one
# arm at a time in a block. Explaining a crossover needs both servers in the same window
# and the same round structure as the measurement that found it.
#
# Usage:
#   bash diag-cell.sh                       # new-req vs rr, /items, c=16
#   CONC=16 ROUNDS=5 DUR=8s bash diag-cell.sh
#   VARIANTS=new-req,new-opt,rr bash diag-cell.sh
#
# Environment:
#   BIN        volucer release binary   (default ~/volucer-bench/target/release/volucer)
#   ROOT       this checkout              (default the script's parent directory)
#   RUNDIR     rows land here             (default ~/volucer-bench-run-cell)
#   RR         RoadRunner binary          (default ~/bin/rr)
set -uo pipefail

# The locale is pinned because the rows are TAB-separated numbers that other tools read
# back. Under a comma-decimal locale `printf '%.3f'` writes `1,000` where the reader
# expects `1.000`, and the row silently becomes a different measurement — found by
# running this on a host whose shell is not in `C`.
export LC_ALL=C

export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
RUNDIR="${RUNDIR:-$HOME/volucer-bench-run-cell}"
RR="${RR:-$HOME/bin/rr}"
VARIANTS="${VARIANTS:-new-req,rr}"
CONC="${CONC:-16}"
DUR="${DUR:-8s}"
ENDPOINT="${ENDPOINT:-/items}"
ROUNDS="${ROUNDS:-5}"
WORKERS="${WORKERS:-12}"
PORT_BASE="${PORT_BASE:-19970}"
WARMUP="${WARMUP:-3s}"

PHP="$(command -v php || true)"
HZ="$(getconf CLK_TCK)"
DIR="$(mktemp -d /tmp/diag-cell.XXXXXX)"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no volucer binary at $BIN"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT"
[ -n "$PHP" ] || fail "no php on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

mkdir -p "$RUNDIR"
RESULTS="$RUNDIR/cpu-cell.tsv"

IFS=',' read -ra VS <<<"$VARIANTS"
N=${#VS[@]}
for v in "${VS[@]}"; do
    [ "$v" = "rr" ] || [ "$v" = "new-req" ] || [ "$v" = "new-opt" ] || fail "unknown variant '$v'"
done
[ "$N" -ge 2 ] || fail "need at least two variants to attribute a difference"

cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench"

port_of() { echo $((PORT_BASE + $2)); }

write_config() {
    local variant="$1" port="$2"
    case "$variant" in
        rr)
            cat > "$DIR/rr.yaml" <<EOF
version: "3"
server:
  command: "$DIR/php-worker-bench $ROOT/roadrunner-worker.php"
  relay: pipes
http:
  address: "127.0.0.1:$port"
  pool:
    num_workers: $WORKERS
    max_jobs: 0
logs:
  mode: production
  level: warn
EOF
            ;;
        *)
            local checksum="required"
            [ "$variant" = "new-opt" ] && checksum="optional"
            cat > "$DIR/$variant.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"
[backends.app]
kind = "worker"
command = "$DIR/php-worker-bench $ROOT/worker.php"
workers = $WORKERS
working_dir = "$ROOT"
max_requests = 0
checksum = "$checksum"
EOF
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Process-tree CPU, walked up the PPID chain from one root pid.
#
# `/proc/<pid>/stat` aggregates every thread, which is what is wanted for the server:
# tokio's threads are part of what its front-end costs. The comm field is
# parenthesised and may contain spaces or parentheses, so the name is the text between
# the FIRST '(' and the LAST ')' and the rest is parsed after the last ') '.
# ---------------------------------------------------------------------------
snapshot_tree() {
    local root="$1" pid line rest name ppid ticks
    declare -A parent=() ticks_of=() comm_of=()

    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        line="$(cat "$d/stat" 2>/dev/null)" || continue
        [ -n "$line" ] || continue
        rest="${line##*) }"
        name="${line%%)*}"; name="${name#*(}"
        ppid="$(awk '{print $2}' <<<"$rest")"
        ticks="$(awk '{print $12 + $13}' <<<"$rest")"
        parent[$pid]="$ppid"
        ticks_of[$pid]="$ticks"
        comm_of[$pid]="$name"
    done

    for pid in "${!ticks_of[@]}"; do
        local p="$pid" depth=0
        while [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$depth" -lt 25 ]; do
            if [ "$p" = "$root" ]; then
                echo "${comm_of[$pid]} ${ticks_of[$pid]}"
                break
            fi
            p="${parent[$p]:-0}"
            depth=$((depth + 1))
        done
    done
}

cpu_by_comm() {
    awk -v hz="$HZ" -v wall="$3" '
        NR == FNR { before[$1] = $2; seen[$1] = 1; next }
        { after[$1] = $2; seen[$1] = 1 }
        END {
            for (c in seen) {
                d = (c in after ? after[c] : 0) - (c in before ? before[c] : 0)
                if (d > 0) printf "%s %.3f\n", c, d / hz / wall
            }
        }
    ' "$1" "$2"
}

snapshot_comm() { awk '{s[$1]+=$2} END{for (c in s) print c, s[c]}' "$1"; }

PID=""
RR_PID=""
stop_variant() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    PID=""
    # Match RoadRunner by its config path, never its binary: its argv is `./rr serve`
    # when started from its own directory, so a pkill on the binary matches nothing and
    # the worker survives holding its port into the next variant. Found twice in bench.sh.
    [ -n "$RR_PID" ] && kill "$RR_PID" 2>/dev/null
    pkill -f "$DIR/rr.yaml" 2>/dev/null
    [ -n "$RR_PID" ] && wait "$RR_PID" 2>/dev/null
    RR_PID=""
}

worker_pids() {
    ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
        $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 { print $1 }'
}

guard_variant() {
    local variant="$1" n pids
    sleep 0.5
    n="$(worker_pids | wc -w | tr -d ' ')"
    [ "$n" = "0" ] && { echo "      leak check [$variant]: clean"; return 0; }
    pids="$(worker_pids)"
    echo "      leak check [$variant]: $n left behind, reaping"
    kill $pids 2>/dev/null; sleep 1
    n="$(worker_pids | wc -w | tr -d ' ')"
    if [ "$n" != "0" ]; then
        kill -9 $(worker_pids) 2>/dev/null; sleep 1
        n="$(worker_pids | wc -w | tr -d ' ')"
        [ "$n" = "0" ] || { echo "      leak check [$variant]: FAILED - $n survived SIGKILL"; exit 1; }
    fi
    echo "      leak check [$variant]: cleared"
}

cleanup() { stop_variant; rm -rf "$DIR"; }
trap cleanup EXIT

wait_port() {
    local port="$1" i
    for i in $(seq 1 160); do
        curl -s -o /dev/null "http://127.0.0.1:$port$ENDPOINT" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

echo "=============================================================="
echo " one cell, CPU attributed on both sides"
echo "=============================================================="
echo "  host:      $(nproc) cores"
echo "  variants:  $VARIANTS"
echo "  endpoint:  $ENDPOINT   concurrency: $CONC   window: $DUR   rounds: $ROUNDS"
echo "  workers:   $WORKERS per pool"
echo "  binary:    $BIN  $(md5sum "$BIN" | cut -d' ' -f1)"
echo "  rr:        $RR"
echo

printf 'round\tvariant\tconc\tendpoint\trps\tserver_cores\tphp_cores\ttotal_cores\tserver_us\tphp_us\ttotal_us\n' \
    >"$RESULTS"

for round in $(seq 1 "$ROUNDS"); do
    for k in $(seq 0 $((N - 1))); do
        variant="${VS[$(( (k + round - 1) % N ))]}"
        port="$(port_of "$variant" "$k")"
        write_config "$variant" "$port"
        case "$variant" in
            rr)
                ( cd "$ROOT" && exec "$RR" serve -c "$DIR/rr.yaml" ) >"$DIR/$variant.log" 2>&1 &
                RR_PID=$!
                ;;
            *)
                "$BIN" serve -c "$DIR/$variant.toml" >"$DIR/$variant.log" 2>&1 &
                PID=$!
                ;;
        esac
        if ! wait_port "$port"; then
            echo "  $variant did not start:"; tail -5 "$DIR/$variant.log"
            stop_variant; guard_variant "$variant"; continue
        fi

        # One warm-up per variant per round, at the highest concurrency the round will
        # measure, so the pool is saturated before the first *reported* window and the
        # per-request figures are steady-state. Concurrency is not sticky, so a lower
        # level after it needs no further warm-up.
        wrk -t"$WORKERS" -c"$WORKERS" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1

        # The server's own pid is the root of the walk, whichever server it is.
        root_pid="$PID"; [ "$variant" = "rr" ] && root_pid="$RR_PID"

        for conc in ${CONC//,/ }; do
            snapshot_tree "$root_pid" | sort >"$DIR/before.txt"
            t0=$(date +%s.%N)
            wrk -t"$conc" -c"$conc" -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" >"$DIR/wrk.txt" 2>&1
            t1=$(date +%s.%N)
            snapshot_tree "$root_pid" | sort >"$DIR/after.txt"

            rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk.txt")"
            wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')"
            snapshot_comm "$DIR/before.txt" >"$DIR/b.txt"
            snapshot_comm "$DIR/after.txt" >"$DIR/a.txt"
            by_comm="$(cpu_by_comm "$DIR/b.txt" "$DIR/a.txt" "$wall")"

            # The server process is `volucer` for one variant and `rr` for the other, and
            # php is the pool on both sides. Naming them separately keeps the two halves
            # apart, which is the whole point of attributing rather than totalling.
            srv="$(awk '$1=="volucer"||$1=="rr"{s+=$2} END{print s+0}' <<<"$by_comm")"
            phpc="$(awk '$1=="php"{s+=$2} END{print s+0}' <<<"$by_comm")"
            tot="$(awk '{s+=$2} END{print s+0}' <<<"$by_comm")"

            printf '%s\t%s\t%s\t%s\t%.0f\t%.3f\t%.3f\t%.3f\t%.0f\t%.0f\t%.0f\n' \
                "$round" "$variant" "$conc" "$ENDPOINT" "$rps" \
                "$srv" "$phpc" "$tot" \
                "$(awk -v r="$rps" -v s="$srv"  'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print 0}')" \
                "$(awk -v r="$rps" -v s="$phpc" 'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print 0}')" \
                "$(awk -v r="$rps" -v s="$tot"  'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print 0}')" \
                >>"$RESULTS"

            printf "    r%-2s %-8s c=%-3s %8s rps  server %4s us  php %4s us  total %4s us  (%s of %s cores)\n" \
                "$round" "$variant" "$conc" "$rps" \
                "$(awk -v r="$rps" -v s="$srv"  'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')" \
                "$(awk -v r="$rps" -v s="$phpc" 'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')" \
                "$(awk -v r="$rps" -v s="$tot"  'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')" \
                "$(awk -v t="$tot" 'BEGIN{printf "%.1f",t}')" "$(nproc)"
        done

        stop_variant
        guard_variant "$variant"
    done
    echo
done

echo "=============================================================="
echo " rows: $RESULTS"
echo "=============================================================="
cat "$RESULTS"
