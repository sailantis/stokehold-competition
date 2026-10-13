#!/bin/bash
# What did the checksum cost, in CPU per request? Three builds, one measurement.
#
# `ab-perf.sh` answers the question in throughput. This answers it in the quantity
# the mechanism actually lives in, and it does so for a reason this project has
# already paid for twice: the checksum was found by CPU attribution after three
# wall-clock passes had failed to localise a 10% gap, and a per-request cost can sit
# entirely inside a throughput number that is bottlenecked somewhere else.
#
# Where the bytes are hashed decides which process pays:
#
#   * the PHP worker computes `crc32c` over the response payload when it writes the
#     `BODY` frame — `hash('crc32c', ...)` in the SDK;
#   * the stokehold server computes it again over the same bytes when it reads the
#     frame back.
#
# So `checksum = "optional"`, which is negotiated in the handshake and makes the
# worker declare `FLAG_NO_CHECKSUM`, removes a hash from *both* sides, while the
# crc32c implementation change removes it only from the server. The two arms are
# therefore expected to differ in different columns, and that is the check on the
# measurement: an arm that moves the PHP column or the server column but not both
# is saying something the mechanism does not predict.
#
#   new-req   current stokehold, checksum = "required"
#   new-opt   current stokehold, checksum = "optional"
#   old-req   pre-crc32c-fix stokehold (hand-written bit-by-bit loop), checksum = "required"
#
# The method is `diag-split.sh`'s: two snapshots of `utime + stime` taken around a
# measured `wrk` run, walked up the PPID chain from the server's own pid, so the
# client cannot leak into the server's column. Names are not used to attribute —
# `comm` is truncated to 15 characters and both `php worker.php` and `php-cgi -b`
# report as `php`/`php-cgi`, so the tree is the fact and the name is a guess.
#
# Usage:
#   bash diag-checksum.sh
#   CONC=32,16 DUR=8s bash diag-checksum.sh
#   ROUNDS=3 bash diag-checksum.sh
#
# Environment:
#   BIN       current stokehold release   (default ~/stoke-bench/target/release/stokehold)
#   BIN_OLD   pre-crc32c-fix release      (default ~/stoke-bench-nocrc/target/release/stokehold)
#   ROOT      this checkout               (default the script's parent directory)
set -uo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
BIN_OLD="${BIN_OLD:-$HOME/stoke-bench-nocrc/target/release/stokehold}"
CONC="${CONC:-32}"
DUR="${DUR:-8s}"
ENDPOINT="${ENDPOINT:-/items}"
ROUNDS="${ROUNDS:-2}"
WORKERS="${WORKERS:-12}"
PORT_BASE="${PORT_BASE:-19950}"
WARMUP="${WARMUP:-3s}"
# The rows go to a stable path, not to the mktemp scratch: a per-request cost is a
# deliverable of this pass the way `results/raw.tsv` is of the sweep, and the temp
# directory is removed by the EXIT trap.
RUNDIR="${RUNDIR:-$HOME/stoke-bench-run-cpu}"

PHP="$(command -v php || true)"
HZ="$(getconf CLK_TCK)"
DIR="$(mktemp -d /tmp/diag-checksum.XXXXXX)"
mkdir -p "$RUNDIR"
CPU_RESULTS="$RUNDIR/cpu-per-request.tsv"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no stokehold binary at $BIN"
[ -x "$BIN_OLD" ] || fail "no pre-fix binary at $BIN_OLD (see the report's revision note)"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT"
[ -n "$PHP" ] || fail "no php on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

PID=""
cleanup() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench"

variant_binary() {
    case "$1" in
        old-req) echo "$BIN_OLD" ;;
        *) echo "$BIN" ;;
    esac
}
variant_checksum() {
    case "$1" in
        new-opt) echo "optional" ;;
        *) echo "required" ;;
    esac
}
variant_port() { echo $((PORT_BASE + $2)); }

write_config() {
    cat > "$DIR/$1.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$2"
document_root = "$ROOT/public"
[backends.app]
kind = "worker"
command = "$DIR/php-worker-bench $ROOT/worker.php"
workers = $WORKERS
working_dir = "$ROOT"
max_requests = 0
checksum = "$(variant_checksum "$1")"
EOF
}

# ---------------------------------------------------------------------------
# Process-tree CPU, attributed by the PPID chain.
#
# `/proc/<pid>/stat` aggregates every thread of a process, which is what is wanted:
# tokio's threads are part of what the front-end costs. The comm field is
# parenthesised and may itself contain spaces or parentheses, so the name is the
# text between the FIRST '(' and the LAST ')', and the fields after it are parsed
# from the remainder. Fields 12 and 13 of that remainder are utime and stime.
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

# comm -> cores used. The two snapshots are CUMULATIVE since process start, so they
# must be subtracted, not added; adding them reports about twice the true cost and
# can exceed the core count, which is how this was caught the first time.
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
    ' "$1" "$2" | sort -k2 -nr
}

snapshot_comm() { awk '{s[$1]+=$2} END{for (c in s) print c, s[c]}' "$1" | sort; }

wait_port() {
    local port="$1" i
    for i in $(seq 1 160); do
        curl -s -o /dev/null "http://127.0.0.1:$port$ENDPOINT" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

echo "=============================================================="
echo " CPU per request: what the frame checksum costs, and where"
echo "=============================================================="
echo "  host:     $(nproc) cores"
echo "  php:      $(php -v | head -1)"
echo "  new BIN:  $BIN   $(md5sum "$BIN" | cut -d' ' -f1)"
echo "  old BIN:  $BIN_OLD   $(md5sum "$BIN_OLD" | cut -d' ' -f1)"
echo "  endpoint: $ENDPOINT   concurrency: $CONC   window: $DUR   rounds: $ROUNDS"
echo "  workers:  $WORKERS (one per core)"
echo

VARIANTS=(new-req new-opt old-req)
printf 'round\tvariant\tconc\tendpoint\tserver_cores\tphp_cores\ttotal_cores\trps\tserver_us\tphp_us\ttotal_us\n' \
    >"$CPU_RESULTS"

for round in $(seq 1 "$ROUNDS"); do
    for k in 0 1 2; do
        variant="${VARIANTS[$(( (k + round - 1) % 3 ))]}"
        port="$(variant_port "$variant" "$k")"
        write_config "$variant" "$port"
        "$(variant_binary "$variant")" serve -c "$DIR/$variant.toml" >"$DIR/$variant.log" 2>&1 &
        PID=$!
        if ! wait_port "$port"; then
            echo "  $variant did not start:"; tail -5 "$DIR/$variant.log"; kill "$PID" 2>/dev/null; PID=""; continue
        fi
        # The arm's own log is kept, so that the `no_checksum=` field it records at the
        # handshake stays available as evidence that the setting took effect — a typo'd
        # key would leave the default in place and make this a comparison between two
        # identical arms.
        grep -o 'no_checksum=[a-z]*' "$DIR/$variant.log" | sort -u | sed 's/^/      handshake /'
        for conc in ${CONC//,/ }; do
            # Unmeasured warm-up, so the pool is saturated and the CPU window matches
            # the throughput window exactly.
            wrk -t"$WORKERS" -c"$WORKERS" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1

            snapshot_tree "$PID" | sort >"$DIR/before.txt"
            t0=$(date +%s.%N)
            wrk -t"$conc" -c"$conc" -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" \
                >"$DIR/wrk.txt" 2>&1
            t1=$(date +%s.%N)
            snapshot_tree "$PID" | sort >"$DIR/after.txt"

            rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk.txt")"
            wall="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')"
            snapshot_comm "$DIR/before.txt" >"$DIR/b.txt"
            snapshot_comm "$DIR/after.txt" >"$DIR/a.txt"
            by_comm="$(cpu_by_comm "$DIR/b.txt" "$DIR/a.txt" "$wall")"

            server="$(awk '$1=="stokehold"{s+=$2} END{print s+0}' <<<"$by_comm")"
            phpc="$(awk '$1=="php"{s+=$2} END{print s+0}' <<<"$by_comm")"
            total="$(awk '{s+=$2} END{print s+0}' <<<"$by_comm")"

            row="$(awk -v r="$round" -v v="$variant" -v c="$conc" -v ep="$ENDPOINT" \
                -v sc="$server" -v pc="$phpc" -v tc="$total" -v rps="$rps" \
                'BEGIN{
                    if (rps>0) { su=sc*1e6/rps; pu=pc*1e6/rps; tu=tc*1e6/rps }
                    else       { su=pu=tu=0 }
                    printf "%s\t%s\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.0f\t%.0f\t%.0f\t%.0f\n",
                           r, v, c, ep, sc, pc, tc, rps, su, pu, tu
                 }')"
            printf '%s\n' "$row" >>"$CPU_RESULTS"

            printf "  r%-2s %-7s c=%-3s  %8s rps   server %5s us  php %5s us  total %5s us\n" \
                "$round" "$variant" "$conc" "$rps" \
                "$(awk -v r="$rps" -v s="$server" 'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')" \
                "$(awk -v r="$rps" -v s="$phpc"   'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')" \
                "$(awk -v r="$rps" -v s="$total"  'BEGIN{if(r>0)printf "%.0f",s*1e6/r; else print "?"}')"
        done
        kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
        sleep 1
    done
    echo
done

echo "=============================================================="
echo " rows: $CPU_RESULTS"
echo "=============================================================="
cat "$CPU_RESULTS"
