#!/bin/bash
# Where does the 10% go? Server CPU versus PHP-worker CPU, per arm.
#
# The published sweep has volucer's warm arm 10% behind RoadRunner's on every
# endpoint at concurrency 32 (16,329 vs 18,258 rps on `/items`), and the two are
# supposed to be the same model: one server, one resident PHP process per slot,
# one request at a time down a pipe. A 10% difference between two implementations
# of the same design is small enough to be worth naming rather than shrugging at,
# and there are only three places it can live:
#
#   (a) volucer's HTTP front-end - accept, parse, `to_cgi`, spawn_blocking,
#       `from_cgi`, write. If this is the difference, it is volucer's code.
#   (b) the worker protocol - how many round trips and how many bytes cross the
#       pipe per request, and whether PHP's read loop is shaped well.
#   (c) the client, or nothing at all - the run is not actually server-bound.
#
# A wall-clock measurement cannot tell these apart, because both servers report
# the same latency and the same rps. CPU can: attribute consumed CPU to each
# process in the arm's process tree and the three collapse into one question -
# *whose* CPU per request is higher.
#
# The method is a process-tree snapshot rather than a match on process names
# (`comm` is truncated to 15 characters, and `php worker.php` reports as `php`
# while `rr serve` reports as `rr` - names are a guess, the PPID chain is not).
# Two samples of `utime + stime` over an interval, walked up the PPID chain from
# the server's own PID, so the client cannot leak into the server's column. The
# snapshot brackets exactly the measured wrk run, after an unmeasured warm-up, so
# the CPU window and the reported throughput are the same period.
#
# T is included deliberately as the control: its ~1,063 us of CPU per request is
# already published, so if this script does not reproduce that, the script is
# wrong and no P-vs-R reading from it means anything.
#
# Usage:
#   bash diag-split.sh                 # P, R, T at concurrency 32
#   ARMS=P,R CONC=32,12 bash diag-split.sh
#   DUR=10s bash diag-split.sh         # longer windows

set -u

ROOT="${ROOT:-$HOME/workspace/volucer-competition}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
RR="${RR:-$HOME/bin/rr}"
ARMS="${ARMS:-P,R,T}"
CONC="${CONC:-32}"
DUR="${DUR:-6s}"
WORKERS="${WORKERS:-12}"
PORT_BASE="${PORT_BASE:-19700}"

PHP="$(command -v php)"
PHP_CGI="$(command -v php-cgi)"
DIR="$(mktemp -d /tmp/diag-split.XXXXXX)"
HZ="$(getconf CLK_TCK)"

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    pkill -f "$DIR/rr.yaml" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

# The same wrappers bench.sh uses, so this measures the same PHP the published
# numbers came from and not the host's CLI defaults. Arms P and R were unwrapped
# once and it cost them 2x - hazard 28 in the volucer plan.
cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
cat > "$DIR/php-cgi-bench" <<WRAPPER
#!/bin/sh
exec $PHP_CGI -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench" "$DIR/php-cgi-bench"

# ---------------------------------------------------------------------------
# Process-tree CPU, attributed by comm.
#
# `snapshot_tree <root_pid>` prints one `comm ticks` line per descendant of root,
# root included. `/proc/<pid>/stat` aggregates every thread of the process, which
# is what we want: tokio's worker threads belong to the server process and are
# part of what the front-end costs.
#
# The comm field is parenthesised and may contain spaces or parentheses, so the
# name is taken as the text between the FIRST '(' and the LAST ')' and the
# remaining fields are parsed after the last ') '. Field 2 of the remainder is
# PPID (field 1 is state), and fields 12 and 13 are utime and stime.
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

# comm -> cores used, from two snapshots. Prints "comm cores" lines, sorted.
#
# The difference, not the sum: `utime + stime` are CUMULATIVE since the process
# started, so the two files have to be subtracted. Adding them instead reports
# roughly twice the true cost and can exceed the machine's core count, which is
# how the first version of this script was caught - a total of 16.36 cores on a
# 12-core host is not a measurement, it is an arithmetic error.
cpu_by_comm() {
    local before="$1" after="$2" wall="$3"
    awk -v hz="$HZ" -v wall="$wall" '
        NR == FNR { before[$1] = $2; seen[$1] = 1; next }
        { after[$1] = $2; seen[$1] = 1 }
        END {
            for (c in seen) {
                d = (c in after ? after[c] : 0) - (c in before ? before[c] : 0)
                if (d > 0) printf "%s %.2f\n", c, d / hz / wall
            }
        }
    ' "$before" "$after" | sort -k2 -nr
}

make_config() {
    local kind="$1" port="$2" file="$3"
    case "$kind" in
        worker)
            cat > "$file" <<EOF
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
EOF
            ;;
        cgi)
            cat > "$file" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = $WORKERS
bind_host = "127.0.0.1"
base_port = $((PORT_BASE + 500))
max_requests = 0
EOF
            ;;
    esac
}

make_rr_config() {
    cat > "$DIR/rr.yaml" <<EOF
version: "3"
server:
  command: "$DIR/php-worker-bench $ROOT/roadrunner-worker.php"
  relay: pipes
http:
  address: "127.0.0.1:$1"
  pool:
    num_workers: $WORKERS
    max_jobs: 0
logs:
  mode: production
  level: warn
EOF
}

wait_port() {
    local port="$1" i
    for i in $(seq 1 200); do
        curl -s -o /dev/null "http://127.0.0.1:$port/items" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

run_case() {
    local arm="$1" conc="$2" port="$3"
    local t0 t1 s0 s1 rps cores

    # An unmeasured warm-up: the first wrk run pays connection setup and lets the
    # pool reach steady state. Discarded, so the measured window is the whole of
    # the second run and the CPU window matches the throughput exactly.
    wrk -t"$conc" -c"$conc" -d3s "http://127.0.0.1:$port/items" >/dev/null 2>&1

    snapshot_tree "$PID" | sort > "$DIR/snap-before.txt"
    t0=$(date +%s.%N)
    wrk -t"$conc" -c"$conc" -d"$DUR" --latency "http://127.0.0.1:$port/items" \
        > "$DIR/wrk-$arm-$conc.txt" 2>&1
    t1=$(date +%s.%N)
    snapshot_tree "$PID" | sort > "$DIR/snap-after.txt"

    rps=$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk-$arm-$conc.txt")
    cores=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')

    # Rebuild two per-comm snapshots rather than summing, so a process that
    # started or died mid-run is visible as a comm appearing in one file only.
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    snapshot_comm "$DIR/snap-before.txt" > "$before"
    snapshot_comm "$DIR/snap-after.txt" > "$after"

    echo
    echo "  === ARM $arm, conc $conc, ${cores}s window, $rps rps ==="
    local by_comm
    by_comm="$(cpu_by_comm "$before" "$after" "$cores")"
    echo "$by_comm" | while read -r comm c; do
        printf "    %-14s %6s cores  %8s us/request\n" \
            "$comm" "$c" "$(awk -v c="$c" -v r="$rps" 'BEGIN{ if (r>0) printf "%.0f", c*1000000/r; else print "?" }')"
    done
    local total server php_total
    total="$(echo "$by_comm" | awk '{s+=$2} END{printf "%.2f", s}')"
    # The server's own share against the workers', which is the comparison that
    # says whether the gap between two implementations is in the front-end.
    server="$(echo "$by_comm" | awk '$1=="volucer"||$1=="rr"{s+=$2} END{printf "%.2f", s}')"
    php_total="$(echo "$by_comm" | awk '$1=="php"||$1=="php-cgi"{s+=$2} END{printf "%.2f", s}')"
    printf "    %-14s %6s cores  %8s us/request\n" \
        "TOTAL" "$total" "$(awk -v c="$total" -v r="$rps" 'BEGIN{ if (r>0) printf "%.0f", c*1000000/r; else print "?" }')"
    printf "    %-14s %6s cores  %8s us/request   <- server process\n" \
        "  of which svr" "$server" "$(awk -v c="$server" -v r="$rps" 'BEGIN{ if (r>0) printf "%.0f", c*1000000/r; else print "?" }')"
    printf "    %-14s %6s cores  %8s us/request   <- PHP workers\n" \
        "  of which php" "$php_total" "$(awk -v c="$php_total" -v r="$rps" 'BEGIN{ if (r>0) printf "%.0f", c*1000000/r; else print "?" }')"
    printf "    %-14s %6s cores  %8s us/request  (%s%% of %s cores busy)\n" \
        "wall" "12.00" "$(awk -v r="$rps" 'BEGIN{ if (r>0) printf "%.0f", 1000000/r; else print "?" }')" \
        "$(awk -v c="$total" 'BEGIN{printf "%.0f", c/12*100}')" "12"
    rm -f "$before" "$after"
}

# Turn a "comm ticks" file into "comm total" so two snapshots can be differenced.
snapshot_comm() {
    awk '{s[$1]+=$2} END{for (c in s) print c, s[c]}' "$1" | sort
}

echo "=============================================================="
echo " CPU per request: server versus PHP, per arm"
echo "=============================================================="
echo "  host:      $(nproc) cores"
echo "  volucer: $($BIN version 2>/dev/null | head -1)"
echo "  php:       $($DIR/php-worker-bench -v 2>/dev/null | head -1)"
echo "  arms:      $ARMS   concurrency: $CONC   window: $DUR   workers: $WORKERS"
if $PHP -m 2>/dev/null | grep -qi '^xdebug$'; then
    echo "  NOTE: xdebug is loaded for the CLI SAPI; the wrapper asks for"
    echo "        xdebug.mode=off, which cannot unload it. Prefer a host without it."
fi

port="$PORT_BASE"
for arm in ${ARMS//,/ }; do
    case "$arm" in
        P)
            make_config worker "$port" "$DIR/pipe.toml"
            "$BIN" serve -c "$DIR/pipe.toml" > "$DIR/server-P.log" 2>&1 &
            PID=$!
            ;;
        T)
            make_config cgi "$port" "$DIR/cgi.toml"
            "$BIN" serve -c "$DIR/cgi.toml" > "$DIR/server-T.log" 2>&1 &
            PID=$!
            ;;
        R)
            make_rr_config "$port"
            ( cd "$ROOT" && "$RR" serve -c "$DIR/rr.yaml" > "$DIR/rr.log" 2>&1 ) &
            PID=$!
            ;;
        *)
            echo "  unknown arm $arm"; continue ;;
    esac

    echo
    echo "--------------------------------------------------------------"
    echo "ARM $arm (pid $PID, port $port)"
    if ! wait_port "$port"; then
        echo "  did not come up:"
        tail -12 "$DIR/server-$arm.log" "$DIR/rr.log" 2>/dev/null
        kill "$PID" 2>/dev/null
        pkill -f "$DIR/rr.yaml" 2>/dev/null
        wait 2>/dev/null
        PID=""
        port=$((port + 1))
        continue
    fi

    for c in ${CONC//,/ }; do
        run_case "$arm" "$c" "$port"
    done

    kill "$PID" 2>/dev/null
    pkill -f "$DIR/rr.yaml" 2>/dev/null
    wait 2>/dev/null
    PID=""
    port=$((port + 1))
    sleep 1
done

echo
echo "Legend: 'php' rows are the resident workers in P and R and the php-cgi"
echo "children in T. In P and R every PHP core is doing application work; in T"
echo "about a third of it is the framework boot the resident arms pay once."
