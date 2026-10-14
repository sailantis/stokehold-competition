#!/bin/bash
# Is a slow tail the pool's queueing, or the load generator's?
#
# The observation this exists to explain: on /items the warm arm's p99 grows from
# ~1.6 ms at concurrency 12 to ~10.4 ms at 24 while its p50 *improves*, and RoadRunner
# on the same box stays flat at ~2.7 ms. Growing tail with a healthy median is the
# shape of queueing, and there are exactly two places it can come from:
#
#   1. The pool. `pick_slot` took each candidate slot's mutex inside its scan loop, so
#      a request waited for whichever worker the cursor pointed at instead of being
#      offered a free one. A slot is held for the whole request, so that wait is a
#      real queue. A free list replaced it (volucer e2b031e); the pool columns below
#      are what showed the defect and what show the fix.
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
#     waiting for a slot (volucer commit 4dd402a). That line is measured inside the
#     server, so it cannot be confused with anything the client did.
#
# One server per thread level, because both figures are cumulative for the life of the
# process and a mean over a swept range describes none of its points. The stop is
# SIGTERM and is *waited for*: the line is printed during a graceful shutdown, so a
# SIGKILL here would silently cost the measurement this whole script is for.
#
# The second mode compares two builds instead of sweeping threads. It exists because the
# fair queue's throughput gain was measured before-vs-after on a blocked layout, which is
# the layout that cannot settle a question of that size: a host drifting over twenty
# minutes charges the drift to whichever build ran last, and this repository has already
# published a 22% "effect" that reversed sign the moment the two binaries were interleaved
# (hazard 49). With VARIANTS set, every build is measured inside the same round and the
# starting order rotates, so the estimator is a within-round ratio and the spread across
# rounds is the error bar.
#
# Usage:
#   bash diag-slots.sh
#   CONC=24 THREADS=2,4,8,12,16,24 bash diag-slots.sh
#
#   CONC=24 THREADS=24 DUR=8s ROUNDS=7 \
#       BIN=~/volucer-bench/target/release/volucer \
#       BIN_PREFAIR=~/volucer-bench-prefair/target/release/volucer \
#       VARIANTS=new,prefair,rr bash diag-slots.sh
#
# Environment:
#   BIN      volucer release binary  (default ~/volucer-bench/target/release/volucer)
#   ROOT     checkout                  (default the script's parent directory)
#   RUNDIR   rows land here            (default ~/volucer-bench-run-slots)
#   VARIANTS optional comma list enabling an interleaved A/B of two or more builds.
#            With one variant this is the thread-count sweep; with two or more, every
#            variant is measured inside the same round and the starting order is
#            rotated by round, so the estimator is a within-round ratio and host
#            drift charges every build equally. Each variant's binary is read from
#            `BIN_<VARIANT>`, e.g. `BIN_PREFAIR` for `prefair`. The reserved name
#            `rr` is RoadRunner, taken from `RR`, and is the control arm.
#   RR       RoadRunner binary         (default ~/bin/rr)
#   ROUNDS   rounds in A/B mode; each round warms up and then measures every variant
set -uo pipefail

# The locale is pinned because the rows are TAB-separated numbers that other tools
# read back. Under a comma-decimal locale `printf '%.3f'` writes `1,000` where the
# reader expects `1.000`, and the row silently becomes a different measurement.
export LC_ALL=C
export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
RUNDIR="${RUNDIR:-$HOME/volucer-bench-run-slots}"
ENDPOINT="${ENDPOINT:-/items}"
CONC="${CONC:-32}"
THREADS="${THREADS:-2,4,8,16,32}"
DUR="${DUR:-8s}"
WARMUP="${WARMUP:-3s}"
WORKERS="${WORKERS:-12}"
REPEATS="${REPEATS:-3}"
PORT="${PORT:-19860}"
# Interleaved A/B. Empty (the default) keeps the original single-build sweep. With
# two or more names every build is measured inside the same round and the starting
# order is rotated, which is the only layout that can settle a few-percent question
# on a host that drifts: a blocked layout charges the drift to whichever build ran
# last, and this repository has published a 22% "effect" that reversed sign the
# moment the two binaries were interleaved instead (hazard 49).
VARIANTS="${VARIANTS:-}"
ROUNDS="${ROUNDS:-1}"
# The control arm. `rr` is a reserved variant name: it is started from a RoadRunner
# config instead of a volucer TOML, and it prints no slot report. It is worth having
# in an A/B because it shares no code with any build of volucer, so a round in which
# every volucer variant moved while `rr` did not is a round in which volucer moved.
RR="${RR:-$HOME/bin/rr}"

PHP="$(command -v php || true)"
DIR="$(mktemp -d /tmp/diag-slots.XXXXXX)"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no volucer binary at $BIN"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT"
[ -n "$PHP" ] || fail "no php on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"
[ "$CONC" -ge 1 ] || fail "CONC must be at least 1"
[ "$ROUNDS" -ge 1 ] || fail "ROUNDS must be at least 1"

# `wrk` on this host rejects sub-second durations: `-d300ms` prints its usage text and
# measures nothing, which the parser below would report as "incomplete wrk output"
# after paying for a whole server start. Catching it here names the real cause, and
# the same guard is what turns a typo in DUR into an error instead of a lost hour.
require_whole_seconds() {
    local name="$1" value="${2%s}"
    case "$value" in
        '' | *[!0-9]*) fail "$name must be whole seconds (e.g. 8s or 8); this wrk rejects sub-second durations" ;;
    esac
    [ "$value" -ge 1 ] || fail "$name must be at least 1 second"
}
require_whole_seconds DUR "$DUR"
require_whole_seconds WARMUP "$WARMUP"

# --- variants ---------------------------------------------------------------------
# One variant is the original sweep; more than one turns this into an interleaved
# A/B. `index_of` and `binary_of` are the only places the variant list is interpreted,
# so adding a build means adding a `BIN_<NAME>` variable and nothing else.
IFS=',' read -ra VARIANT_LIST <<<"$VARIANTS"
if [ -z "$VARIANTS" ]; then
    VARIANT_LIST=(--sweep)
fi
NVARIANTS="${#VARIANT_LIST[@]}"

index_of() {
    local i=0 v
    for v in "${VARIANT_LIST[@]}"; do
        [ "$v" = "$1" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    echo "-1"
}

# `binary_of` looks up `BIN_<VARIANT>` with the name upper-cased and non-alphanumerics
# turned into underscores, so `prefair` reads `BIN_PREFAIR`. `--sweep` is the single
# unnamed build and uses `BIN`.
binary_of() {
    local upper name
    if [ "$1" = "--sweep" ]; then
        echo "$BIN"
        return 0
    fi
    upper="$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"
    name="BIN_$upper"
    echo "${!name:-$BIN}"
}

# Each variant gets its own config file and its own port, so two builds never share a
# port and a stale process can never be mistaken for the current one. The port follows
# the variant's index in the list, which is the same order the rotation walks.
port_of() { echo "$((PORT + $(index_of "$1")))"; }
config_of() {
    case "$1" in
        --sweep) echo "$DIR/worker.toml" ;;
        rr) echo "$DIR/rr.yaml" ;;
        *) echo "$DIR/$1.toml" ;;
    esac
}

write_variant_config() {
    local variant="$1" port="$2" file="$3"
    # `rr` is not a volucer backend: it gets a RoadRunner YAML and is started from the
    # app root so `rr serve` finds the worker path relative to it. Pool size and the PHP
    # wrapper match the volucer configs exactly, because the pair exists to compare
    # servers, not pool sizes or PHP inis (hazard 28).
    if [ "$variant" = "rr" ]; then
        cat > "$file" <<EOF
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
        return 0
    fi
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
}

if [ "$NVARIANTS" -eq 1 ] && [ "${VARIANT_LIST[0]}" = "--sweep" ]; then
    write_variant_config --sweep "$(port_of --sweep)" "$DIR/worker.toml"
else
    for v in "${VARIANT_LIST[@]}"; do
        case "$v" in
            *[!A-Za-z0-9_-]*) fail "variant '$v' must be alphanumeric, '-' or '_' (it names BIN_*)" ;;
        esac
        [ "$v" != "--sweep" ] || fail "'--sweep' is reserved for the single unnamed build"
        if [ "$v" = "rr" ]; then
            [ -x "$RR" ] || fail "variant 'rr' needs the RoadRunner binary: set RR"
        else
            [ -x "$(binary_of "$v")" ] || fail "variant '$v' needs a binary: set BIN_$(tr '[:lower:]-' '[:upper:]_' <<<"$v")"
        fi
        write_variant_config "$v" "$(port_of "$v")" "$(config_of "$v")"
    done
fi

mkdir -p "$RUNDIR"
RESULTS="$RUNDIR/slots.tsv"

cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench"


PID=""

# SIGTERM, then wait for it. The line this script reads is printed while the process is
# going down, so the wait is part of the measurement rather than tidiness, and the log is
# only read once the process has actually exited.
#
# RoadRunner is matched by its CONFIG PATH, not by its binary name: started as `rr serve`
# its argv does not contain the binary's full path, so a pkill on `rr` matches nothing and
# the worker survives, holding its port into the next variant. Found twice in bench.sh.
stop_server() {
    [ -n "$PID" ] || return 0
    kill "$PID" 2>/dev/null
    pkill -f "$DIR/rr.yaml" 2>/dev/null

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

# The pool's own line, if it was printed. RoadRunner prints none, and that absence is
# expected rather than a failure: its slot columns are left empty in the row.
slots_line() {
    grep -h '^slots: ' "$1" 2>/dev/null | tail -1
}

# The token before / after a given word, for reading the report line by label rather
# than by position.
word_before() { awk -v k="$2" '{for(i=2;i<=NF;i++) if($i==k) print $(i-1)}' <<<"$1"; }
word_after()  { awk -v k="$2" '{for(i=1;i<NF;i++)  if($i==k) print $(i+1)}' <<<"$1"; }

leak_check() {
    local variant="${1:-}" n pids
    # A volucer variant's children are `php .../worker.php`; RoadRunner's are
    # `php .../roadrunner-worker.php`. Matching the script path is unambiguous — no host
    # service runs a worker from this checkout — and `-ww` is load-bearing: without it the
    # argv is truncated to the terminal width and the path is lost, which is exactly how
    # the guard in bench.sh came to match nothing while twelve children were alive.
    pids="$(ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
        $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 {
            print $1
        }')"
    n="$(wc -w <<<"$pids" | tr -d ' ')"
    [ "$n" = "0" ] && return 0
    echo "  leak check [$variant]: $n worker(s) left behind: $(tr '\n' ' ' <<<"$pids")" >&2
    # The server's own Drop reaps its children; give it the moment it needs before
    # concluding anything, and refuse to continue if a leak cannot be cleared.
    sleep 0.5
    pids="$(ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
        $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 {
            print $1
        }')"
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null
        sleep 1
        pids="$(ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
            $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 {
                print $1
            }')"
        if [ -n "$pids" ]; then
            kill -9 $pids 2>/dev/null
            sleep 1
            n="$(ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
                $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 {print $1}' | wc -w | tr -d ' ')"
            [ "$n" = "0" ] || { echo "  leak check [$variant]: FAILED - $n survived SIGKILL" >&2; exit 1; }
        fi
    fi
    echo "  leak check [$variant]: cleared" >&2
}

cleanup() {
    stop_server
    rm -rf "$DIR"
}
trap cleanup EXIT

wait_port() {
    local port="$1" tries=0
    while [ "$tries" -lt 200 ]; do
        if curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

if [ "$NVARIANTS" -eq 1 ] && [ "${VARIANT_LIST[0]}" = "--sweep" ]; then
    SWEEP_MODE=1
else
    SWEEP_MODE=0
fi

if [ "$SWEEP_MODE" = "1" ]; then
    # The original column layout, kept byte-compatible with the committed slot-wait rows
    # (`slot-waits-A.tsv`, `-B.tsv`, `-fair-A.tsv`, `-fair-B.tsv`). A parser that reads by
    # position rather than by header name would silently shift if these columns moved, and
    # the report quotes those files.
    printf 'workers\tconc\tthreads\trepeat\trps\tp50\tp99\tserved\tmean_wait_us\twait_p50_us\twait_p99_us\tbusiest\tbusiest_wait_us\n' \
        > "$RESULTS"
else
    # A/B mode prepends the variant and renames `repeat` to `round`, because in this mode a
    # row's repeat index is the round it was measured in and the round is what the ratio is
    # computed within.
    printf 'variant\tworkers\tconc\tthreads\tround\trps\tp50\tp99\tserved\tmean_wait_us\twait_p50_us\twait_p99_us\tbusiest\tbusiest_wait_us\n' \
        > "$RESULTS"
fi

if [ "$NVARIANTS" -eq 1 ] && [ "${VARIANT_LIST[0]}" = "--sweep" ]; then
    echo "diag-slots: $WORKERS worker(s), concurrency $CONC held fixed, threads $THREADS"
    echo "            endpoint $ENDPOINT, $DUR per run, $REPEATS repeat(s) per thread count"
else
    echo "diag-slots: interleaved A/B, $WORKERS worker(s), concurrency $CONC held fixed"
    echo "            endpoint $ENDPOINT, $DUR per run, $ROUNDS round(s), variants $VARIANTS"
    echo "            rotation: round r starts at variant r mod $NVARIANTS"
fi
echo ""

IFS=',' read -ra LEVELS <<<"$THREADS"

# ---------------------------------------------------------------------------
# One measured cell: start the server for this variant, warm it, run wrk, stop
# it, and read the pool's own report out of its log. The server is restarted per
# measurement because both figures the pool prints are cumulative for the life
# of the process; a mean over a swept range describes none of its points.
# ---------------------------------------------------------------------------
run_measurement() {
    local variant="$1" port="$2" threads="$3" round="$4"
    local log="$DIR/server-$variant.log"

    : > "$log"
    if [ "$variant" = "rr" ]; then
        # `rr serve` resolves the worker path relative to its working directory, so it has
        # to be started from the app root; `-c` points at the temp YAML.
        ( cd "$ROOT" && exec "$RR" serve -c "$DIR/rr.yaml" ) >>"$log" 2>&1 &
        PID=$!
    else
        "$(binary_of "$variant")" serve -c "$(config_of "$variant")" >>"$log" 2>&1 &
        PID=$!
    fi

    if ! wait_port "$port"; then
        echo "  server never answered on port $port" >&2
        tail -5 "$log" >&2
        stop_server || true
        return 1
    fi

    # Unmeasured warm-up: first-touch opcache and a cold worker both belong to the
    # setup, not to the measurement.
    wrk -t"$threads" -c"$CONC" -d"$WARMUP" "http://127.0.0.1:$port$ENDPOINT" >/dev/null 2>&1

    wrk -t"$threads" -c"$CONC" -d"$DUR" --latency "http://127.0.0.1:$port$ENDPOINT" \
        >"$DIR/wrk.txt" 2>&1

    local rps p50 p99
    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk.txt")"
    p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' "$DIR/wrk.txt")"
    p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' "$DIR/wrk.txt")"

    if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
        echo "  $variant r=$round t=$threads: incomplete wrk output (d=${DUR})" >&2
        head -3 "$DIR/wrk.txt" >&2
        stop_server || true
        return 1
    fi

    # A bounded pool can convert a latency tail into a throughput number by answering
    # 503 instead of serving, which looks exactly like the fix working. `wrk` prints
    # every non-2xx response on its own line, so its absence is the check that nothing
    # was shed. This is not cosmetic: the current pool has a 500 ms slot-wait ceiling
    # precisely so it refuses rather than queues forever, so a run that refuses is a
    # real possibility rather than a hypothetical one.
    local nonshed
    nonshed="$(grep -E 'Non-2xx|Socket errors' "$DIR/wrk.txt" | head -3)"
    if [ -n "$nonshed" ]; then
        echo "  $variant r=$round t=$threads: NOT a clean sweep — wrk reported:" >&2
        echo "$nonshed" >&2
        shed_note="$(tr '\n' ';' <<<"$nonshed")"
    else
        shed_note=""
    fi

    stop_server
    # Anchored on the words rather than on field numbers, and named for the line
    # they read: `slots: 12 worker(s), 40000 request(s), mean wait 812 us, busiest
    # slot 7 at 41233 us`. Counting fields instead would silently shift the moment
    # any part of that line changes, and a wrong number here reads as a measurement.
    local line
    line="$(slots_line "$log")"
    if [ -z "$line" ]; then
        if [ "$variant" = "rr" ]; then
            # RoadRunner is the control: it shares no code with volucer and prints no
            # slot report, so its pool columns are left empty rather than invented.
            line=""
        else
            # Not a `?` in the row: the pool columns are the whole point of this script,
            # and a row whose columns say nothing would be spent against a measurement
            # that cannot be made. The two ways to get here are both worth failing on,
            # so both are named.
            echo "FATAL: the server printed no slot-contention report at shutdown." >&2
            echo "       Either this binary predates the report (volucer 4dd402a), or it" >&2
            echo "       did not shut down gracefully and the report was never reached." >&2
            echo "       variant=$variant BIN=$(binary_of "$variant")" >&2
            echo "       last lines of the server log:" >&2
            tail -5 "$log" >&2
            exit 1
        fi
    fi
    local served mean wait_p50 wait_p99 busiest busiest_us
    served="$(word_before "$line" 'request(s),')"
    mean="$(word_after "$line" 'mean')"
    wait_p50="$(word_after "$line" 'p50')"
    wait_p99="$(word_after "$line" 'p99')"
    busiest="$(word_after "$line" 'slot')"
    busiest_us="$(word_after "$line" 'at')"

    if [ "$SWEEP_MODE" = "1" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$WORKERS" "$CONC" "$threads" "$round" \
            "$rps" "$p50" "$p99" \
            "${served:-?}" "${mean:-?}" "${wait_p50:-?}" "${wait_p99:-?}" \
            "${busiest:-?}" "${busiest_us:-?}" >> "$RESULTS"
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$variant" "$WORKERS" "$CONC" "$threads" "$round" \
            "$rps" "$p50" "$p99" \
            "${served:-?}" "${mean:-?}" "${wait_p50:-?}" "${wait_p99:-?}" \
            "${busiest:-?}" "${busiest_us:-?}" >> "$RESULTS"
    fi

    printf "  r%-2s %-9s t=%-4s  %10s rps  p50 %8s  p99 %8s" \
        "$round" "$variant" "$threads" "$rps" "$p50" "$p99"
    if [ -n "$line" ]; then
        printf "  |  pool wait: mean %-6s p50 %-6s p99 %-7s us  (busiest slot %s at %s us)" \
            "${mean:-?}" "${wait_p50:-?}" "${wait_p99:-?}" "${busiest:-?}" "${busiest_us:-?}"
    fi
    if [ -n "$shed_note" ]; then
        printf "  |  SHED LOAD: %s" "$shed_note"
    fi
    printf "\n"

    leak_check "$variant"
    return 0
}

if [ "$NVARIANTS" -eq 1 ] && [ "${VARIANT_LIST[0]}" = "--sweep" ]; then
    for t in "${LEVELS[@]}"; do
        for rep in $(seq 1 "$REPEATS"); do
            run_measurement --sweep "$(port_of --sweep)" "$t" "$rep"
        done
    done
else
    # Round-major, variant-rotated. Every variant is measured inside the same round, so
    # the estimator is a within-round ratio and a drift of any shape charges every build
    # equally often. This is the only layout that can settle a few-percent question.
    #
    # Two passes over the variants per round. The first pays for what only the *first*
    # start pays for — a cold filesystem cache on the binaries, a cold opcache in the
    # workers — and is discarded. Without it the variant that happens to go first in
    # round 1 carries a penalty no later variant does. `ROUNDS` therefore counts pairs.
    for round in $(seq 1 "$ROUNDS"); do
        echo "ROUND $round of $ROUNDS"
        for k in $(seq 0 $((NVARIANTS - 1))); do
            first="${VARIANT_LIST[$(( (k + round - 1) % NVARIANTS ))]}"
            echo "  warm-up (discarded): $first"
            # Truncate to the line count from before rather than deleting the last line:
            # a warm-up that fails appends nothing, and `sed '$d'` would then eat a real
            # row from a previous round.
            keep="$(wc -l < "$RESULTS")"
            if ! run_measurement "$first" "$(port_of "$first")" "$THREADS" "$round"; then
                echo "  [WARN] warm-up for $first did not measure; continuing to the round" >&2
            fi
            head -n "$keep" "$RESULTS" > "$RESULTS.keep" && mv "$RESULTS.keep" "$RESULTS"
        done
        for k in $(seq 0 $((NVARIANTS - 1))); do
            variant="${VARIANT_LIST[$(( (k + round - 1) % NVARIANTS ))]}"
            run_measurement "$variant" "$(port_of "$variant")" "$THREADS" "$round" || true
        done
        echo ""
    done
fi

echo ""
echo "rows: $RESULTS"
echo ""
if [ "$NVARIANTS" -gt 1 ]; then
    echo "Interleaved A/B. Every variant was measured inside the same round with the"
    echo "starting order rotated, so the estimator is the ratio of two rps measured"
    echo "within one round and the spread of those ratios across rounds is the error"
    echo "bar. A ratio whose spread spans 1.00 is no evidence at all, however far its"
    echo "median sits from it."
    echo ""
    echo "  python3 scripts/slots-report.py $RESULTS"
    echo ""
fi
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