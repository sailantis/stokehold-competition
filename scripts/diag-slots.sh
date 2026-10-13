#!/bin/bash
# Is a slow tail the pool's queueing, or the load generator's?
#
# The observation this exists to explain: on /items the warm arm's p99 grows from
# ~1.6 ms at concurrency 12 to ~10.4 ms at 24 while its p50 *improves*, and RoadRunner
# on the same box stays flat at ~2.7 ms. Growing tail with a healthy median is the
# shape of queueing, and there are exactly two places it can come from:
#
#   1. The pool. `pick_slot` takes each candidate slot's mutex inside its scan loop,
#      so a request waits for whichever worker the cursor pointed at instead of being
#      offered a free one. A slot is held for the whole request, so that wait is a
#      real queue.
#   2. The client. Every harness here drives wrk as `-t$c -c$c`, so concurrency *is*
#      the client's thread count. At c=16 the load generator owns 16 threads while
#      the server owns 12 workers, and wrk's p99 includes its own threads waiting to
#      be scheduled on cores the server is already using. That is a measurement
#      artifact that would chase a phantom fix in the wrong process.
#
# `diag-cell.sh` cannot separate them: it attributes CPU per process, and both
# candidates cost CPU on the same box. This separates them by holding concurrency
# fixed and varying *only* the thread count, which changes nothing on the server side
# at all. The server sees c=32 connections either way.
#
#   - If p99 collapses as threads drop, the tail is the load generator's scheduling.
#   - If p99 stays put, it is not, and the pool's own figure says whether it is the
#     pool: the server prints, at shutdown, the mean and worst time requests spent
#     waiting for a slot (stokehold commit 4dd402a). That line is measured inside the
#     server, so it cannot be confused with anything the client did.
#
# One server per thread level, because both figures are cumulative for the life of the
# process and a mean over a swept range describes none of its points. The stop is
# SIGTERM and is *waited for*: the line is printed during a graceful shutdown, so a
# SIGKILL here would silently cost the measurement this whole script is for.
#
# Usage:
#   bash diag-slots.sh
#   CONC=24 THREADS=2,4,8,12,16,24 bash diag-slots.sh
#
# Environment:
#   BIN      stokehold release binary  (default ~/stoke-bench/target/release/stokehold)
#   ROOT     checkout                  (default the script's parent directory)
#   RUNDIR   rows land here            (default ~/stoke-bench-run-slots)
set -uo pipefail

# The locale is pinned because the rows are TAB-separated numbers that other tools
# read back. Under a comma-decimal locale `printf '%.3f'` writes `1,000` where the
# reader expects `1.000`, and the row silently becomes a different measurement.
export LC_ALL=C
export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
RUNDIR="${RUNDIR:-$HOME/stoke-bench-run-slots}"
ENDPOINT="${ENDPOINT:-/items}"
CONC="${CONC:-32}"
THREADS="${THREADS:-2,4,8,16,32}"
DUR="${DUR:-8s}"
WARMUP="${WARMUP:-3s}"
WORKERS="${WORKERS:-12}"
REPEATS="${REPEATS:-3}"
PORT="${PORT:-19860}"

PHP="$(command -v php || true)"
DIR="$(mktemp -d /tmp/diag-slots.XXXXXX)"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no stokehold binary at $BIN"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT"
[ -n "$PHP" ] || fail "no php on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"
[ "$CONC" -ge 1 ] || fail "CONC must be at least 1"

mkdir -p "$RUNDIR"
RESULTS="$RUNDIR/slots.tsv"

cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench"

cat > "$DIR/worker.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$PORT"
document_root = "$ROOT/public"
[backends.app]
kind = "worker"
command = "$DIR/php-worker-bench $ROOT/worker.php"
workers = $WORKERS
working_dir = "$ROOT"
max_requests = 0
EOF

PID=""

# SIGTERM, then wait for it. The line this script reads is printed while the process is
# going down, so the wait is part of the measurement rather than tidiness, and the log is
# only read once the process has actually exited.
stop_server() {
    [ -n "$PID" ] || return 0
    kill "$PID" 2>/dev/null

    local waited=0
    while [ "$waited" -lt 100 ]; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
        waited=$((waited + 1))
    done

    if kill -0 "$PID" 2>/dev/null; then
        echo "  server did not stop on SIGTERM; killing it (no report this level)" >&2
        kill -9 "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
        PID=""
        return 1
    fi
    wait "$PID" 2>/dev/null
    PID=""
    return 0
}

# The pool's own line, if it was printed.
slots_line() {
    grep -h '^slots: ' "$DIR/server.log" 2>/dev/null | tail -1
}

# The token before / after a given word, for reading the report line by label rather
# than by position.
word_before() { awk -v k="$2" '{for(i=2;i<=NF;i++) if($i==k) print $(i-1)}' <<<"$1"; }
word_after()  { awk -v k="$2" '{for(i=1;i<NF;i++)  if($i==k) print $(i+1)}' <<<"$1"; }

leak_check() {
    local n
    n="$(pgrep -f "$ROOT/worker.php" 2>/dev/null | wc -l)"
    if [ "$n" != "0" ]; then
        echo "  leak check: FAILED - $n worker(s) survived" >&2
        pgrep -f "$ROOT/worker.php" 2>/dev/null | while read -r p; do kill -9 "$p" 2>/dev/null; done
        exit 1
    fi
}

cleanup() {
    stop_server
    rm -rf "$DIR"
}
trap cleanup EXIT

wait_port() {
    local tries=0
    while [ "$tries" -lt 200 ]; do
        if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

printf 'workers\tconc\tthreads\trepeat\trps\tp50\tp99\tserved\tmean_wait_us\twait_p50_us\twait_p99_us\tbusiest\tbusiest_wait_us\n' \
    > "$RESULTS"

echo "diag-slots: $WORKERS worker(s), concurrency $CONC held fixed, threads $THREADS"
echo "            endpoint $ENDPOINT, ${DUR} per run, $REPEATS repeat(s) per thread count"
echo ""

if [ ! -f "$RESULTS" ] || [ "$(wc -l < "$RESULTS")" -le 1 ]; then
    : > "$RESULTS"
    printf 'workers\tconc\tthreads\trepeat\trps\tp50\tp99\tserved\tmean_wait_us\twait_p50_us\twait_p99_us\tbusiest\tbusiest_wait_us\n' \
        >> "$RESULTS"
fi

IFS=',' read -ra LEVELS <<<"$THREADS"

for t in "${LEVELS[@]}"; do
    for rep in $(seq 1 "$REPEATS"); do
        : > "$DIR/server.log"
        "$BIN" serve -c "$DIR/worker.toml" >>"$DIR/server.log" 2>&1 &
        PID=$!

        if ! wait_port; then
            echo "  server never answered on port $PORT" >&2
            tail -5 "$DIR/server.log" >&2
            stop_server || true
            continue
        fi

        # Unmeasured warm-up: first-touch opcache and a cold worker both belong to the
        # setup, not to the measurement.
        wrk -t"$t" -c"$CONC" -d"$WARMUP" "http://127.0.0.1:$PORT$ENDPOINT" >/dev/null 2>&1

        wrk -t"$t" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$PORT$ENDPOINT" \
            >"$DIR/wrk.txt" 2>&1

        rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk.txt")"
        p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' "$DIR/wrk.txt")"
        p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' "$DIR/wrk.txt")"

        if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
            echo "  t=$t rep=$rep: incomplete wrk output" >&2
            stop_server || true
            continue
        fi

        stop_server
        # Anchored on the words rather than on field numbers, and named for the line
        # they read: `slots: 12 worker(s), 40000 request(s), mean wait 812 us, busiest
        # slot 7 at 41233 us`. Counting fields instead would silently shift the moment
        # any part of that line changes, and a wrong number here reads as a measurement.
        line="$(slots_line)"
        if [ -z "$line" ]; then
            # Not a `?` in the row: the pool columns are the whole point of this script,
            # and a row whose columns say nothing would be spent against a measurement
            # that cannot be made. The two ways to get here are both worth failing on,
            # so both are named.
            echo "FATAL: the server printed no slot-contention report at shutdown." >&2
            echo "       Either this binary predates the report (stokehold 4dd402a), or it" >&2
            echo "       did not shut down gracefully and the report was never reached." >&2
            echo "       BIN=$BIN" >&2
            echo "       last lines of the server log:" >&2
            tail -5 "$DIR/server.log" >&2
            exit 1
        fi
        served="$(word_before "$line" 'request(s),')"
        mean="$(word_after "$line" 'mean')"
        wait_p50="$(word_after "$line" 'p50')"
        wait_p99="$(word_after "$line" 'p99')"
        busiest="$(word_after "$line" 'slot')"
        busiest_us="$(word_after "$line" 'at')"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$WORKERS" "$CONC" "$t" "$rep" "$rps" "$p50" "$p99" \
            "${served:-?}" "${mean:-?}" "${wait_p50:-?}" "${wait_p99:-?}" "${busiest:-?}" "${busiest_us:-?}" >> "$RESULTS"

        printf "  c=%-3s t=%-3s rep %s  %10s rps  p50 %8s  p99 %8s  |  pool wait: mean %-6s p50 %-6s p99 %-7s us  (served %s, busiest slot %s at %s us)\n" \
            "$CONC" "$t" "$rep" "$rps" "$p50" "$p99" \
            "${mean:-?}" "${wait_p50:-?}" "${wait_p99:-?}" "${served:-?}" "${busiest:-?}" "${busiest_us:-?}"

        leak_check
    done
done

echo ""
echo "rows: $RESULTS"
echo ""
echo "Read the pool wait p99 against the client p99, and both against the thread count."
echo "Concurrency is unchanged for every row, so the server does the same work in all of"
echo "them and any difference in the client p99 belongs to the load generator. The pool wait"
echo "columns are measured inside the server and cannot include anything the client did."
echo ""
echo "  - If the pool wait p99 stays put as t falls while the client p99 falls, the tail is"
echo "    the load generator and no pool fix would have moved it."
echo "  - If the pool wait p99 tracks the client p99, the queueing is real. A pool p50 near"
echo "    its mean with a p99 in whole milliseconds is unfairness: most requests are served"
echo "    at once and a few wait for entire requests, which is a latency tail even when"
echo "    throughput is fine."