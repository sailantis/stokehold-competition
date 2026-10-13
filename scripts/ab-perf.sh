#!/bin/bash
# Is the effect still there? An interleaved A/B of the warm arm, in one process.
#
# `bench.sh` answers "how fast is each deployment", one arm at a time: P, then T,
# then U, then R, then F, each measured in a block. That layout is the right one
# for eight independent arms, and the wrong one for a 3% question, because a host
# that drifts monotonically over twenty minutes charges the drift to whichever arm
# ran last. This repository has already published a 22% "effect" that reversed sign
# when the same two binaries were interleaved instead of blocked (hazard 49), and
# the same trap caught the `worker_pool.rs` split, which read as -3.3% until the
# two binaries were alternated `A,B,B,A`.
#
# So this script exists to do one thing: run every variant inside the same round,
# and rotate which variant goes first, so that a drift of *any* shape lands on
# every variant equally often. The estimator is then not the difference between
# two medians but the pair of ratios measured within a single round, and the
# spread of those ratios across rounds is the error bar.
#
#   variant    what it is
#   new-req    current stokehold, checksum = "required"   (what the sweep measured)
#   new-opt    current stokehold, checksum = "optional"   (does skipping it help?)
#   old-req    pre-crc32c-fix stokehold, checksum = "required"  (what the fix bought)
#   rr         RoadRunner, resident worker                 (the control)
#   franken    FrankenPHP, worker mode                     (embedded-runtime control)
#
# `rr` is the control and the reason this is an A/B and not a trend: it shares no
# code with any other variant, so a round in which every stokehold variant moved
# but `rr` did not is a round in which stokehold moved, and a round in which both
# moved together is the host.
#
# `franken` is a second control of a different kind, and it earns its place by being
# the one arm that answers an architectural question rather than a tuning one.
# FrankenPHP embeds the PHP interpreter inside its own process — a Caddy server with
# a ZTS PHP built into the binary — which is exactly what stokehold rejects on
# purpose (no embedding, no FFI, PHP is always an external process; see the plan's
# constraints). Every other variant here spawns PHP; this one IS PHP. It runs
# `frankenphp-worker.php`, which drives the same `BenchApp` as `worker.php` and
# `roadrunner-worker.php` with the same worker count, so warm-vs-warm is held equal
# and the only difference left is the runtime underneath.
#
# It is NOT a like-for-like PHP: the release binary bundles PHP 8.5.11 against this
# host's 8.3.35. See the note in `conf/frankenphp.caddyfile.template` — it is stated
# as a confound rather than corrected, because the alternative is not measuring the
# server people actually deploy.
#
# Its per-arm log is also where the embedded runtime's effective ini is read back
# from inside a worker thread, which is the only way to see hazard 28 coming: the
# release binary loads no php.ini at all, so without the Caddyfile's `php_ini` it
# would run the whole arm at PHP's compiled-in defaults (128M, timestamp validation
# on) while every other arm ran 512M and off.
#
# The `old-req` variant is a targeted revert rather than an old checkout: the
# crate-backed `crc32c` in `stokehold-worker/src/header.rs` is replaced with the
# hand-written bit-by-bit loop it replaced, so the only difference from `new-req`
# is that one function on the response path. See the header of the report's
# revision note for how the binary is built. It is behaviourally identical — both
# binaries return byte-identical bodies — and the pinned-value test still passes,
# because the value is what has to match, not the implementation.
#
# Usage:
#   bash ab-perf.sh                                # every variant, both endpoints
#   VARIANTS=new-req,new-opt,rr bash ab-perf.sh    # a subset
#   ROUNDS=9 CONC=8,16,32 DUR=5s bash ab-perf.sh
#   ENDPOINTS=/items bash ab-perf.sh
#
# Environment:
#   BIN       current stokehold release   (default ~/stoke-bench/target/release/stokehold)
#   BIN_OLD   pre-crc32c-fix release      (default ~/stoke-bench-nocrc/target/release/stokehold)
#   ROOT      this checkout               (default the script's parent directory)
#   RUNDIR    scratch + results           (default ~/stoke-bench-run-ab)
#   RR        RoadRunner binary           (default ~/bin/rr)
#   FP        FrankenPHP binary           (default ~/bin/frankenphp)
#
# The FrankenPHP arm needs no php.ini beside its binary and no wrapper script: its
# ini is set by `php_ini` in the Caddyfile the script stamps, which acts on the
# interpreter inside the worker threads. A `php.ini` left in the working directory
# would do the same thing by a second route and make "which one applied" ambiguous,
# so don't add one.
set -uo pipefail

# The locale is pinned because the rows are TAB-separated numbers that other tools read
# back. Under a comma-decimal locale `printf '%.3f'` writes `1,000` where the reader
# expects `1.000`, and the row silently becomes a different measurement.
export LC_ALL=C

export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
BIN_OLD="${BIN_OLD:-$HOME/stoke-bench-nocrc/target/release/stokehold}"
RUNDIR="${RUNDIR:-$HOME/stoke-bench-run-ab}"
RR="${RR:-$HOME/bin/rr}"
FP="${FP:-$HOME/bin/frankenphp}"
VARIANTS="${VARIANTS:-new-req,new-opt,old-req,rr,franken}"
CONC="${CONC:-8,16,32}"
DUR="${DUR:-5s}"
ROUNDS="${ROUNDS:-7}"
ENDPOINTS="${ENDPOINTS:-/,/items}"
WORKERS="${WORKERS:-12}"
PORT_BASE="${PORT_BASE:-19900}"
# Seconds of unmeasured load before each variant's first cell of a round. The pool
# must be saturated before the first measured cell or the round-1 sample of the
# first variant is a cold-start number, which is exactly the kind of asymmetry the
# rotation exists to remove.
WARMUP="${WARMUP:-2s}"

PHP="$(command -v php || true)"
PHP_CGI="$(command -v php-cgi || true)"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no stokehold binary at $BIN (set BIN)"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT (set ROOT)"
[ -d "$ROOT/vendor" ] || fail "$ROOT/vendor is missing - run: composer install"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
[ -n "$PHP" ] || fail "no php on PATH"
command -v wrk >/dev/null 2>&1 || fail "no wrk on PATH"

mkdir -p "$RUNDIR"
RESULTS="$RUNDIR/ab-rps.tsv"

# ---------------------------------------------------------------------------
# The same PHP the published sweep used, for the same reason: an unwrapped
# `php` is exposed to whatever the host's CLI has installed, and on this host
# that was xdebug (hazard 28) at roughly 2x. Variants that differ in anything
# measure nothing.
# ---------------------------------------------------------------------------
PHP_WORKER_WRAPPER="$RUNDIR/php-worker-bench"
cat > "$PHP_WORKER_WRAPPER" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_WORKER_WRAPPER"

# --- variant -> index, binary, config path, port ---------------------------------
variant_index() {
    local i=0 v
    for v in ${VARIANTS//,/ }; do
        [ "$v" = "$1" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    echo "-1"
}

port_of() { echo $((PORT_BASE + $(variant_index "$1"))); }

binary_of() {
    case "$1" in
        old-req | old-opt) echo "$BIN_OLD" ;;
        *) echo "$BIN" ;;
    esac
}

# `required` is the default and what every published number used; spelling it out
# keeps the three stokehold rows visually comparable in the generated config.
checksum_of() {
    case "$1" in
        *-opt) echo "optional" ;;
        *) echo "required" ;;
    esac
}

write_config() {
    local variant="$1" port file
    port="$(port_of "$variant")"
    file="$RUNDIR/$variant.toml"
    case "$variant" in
        rr)
            cat > "$RUNDIR/$variant.yaml" <<EOF
version: "3"
server:
  command: "$PHP_WORKER_WRAPPER $ROOT/roadrunner-worker.php"
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
        franken)
            # Stamped from the arm's real template rather than inlined, so the
            # directive that makes the difference here — `match /*`, without which
            # `php_server` silently serves the *cold* path and the arm measures the
            # wrong model — lives in exactly one place.
            sed -e "s#{{ROOT}}#$ROOT#g" -e "s#{{PORT}}#$port#g" -e "s#{{WORKERS}}#$WORKERS#g" \
                "$ROOT/conf/frankenphp.caddyfile.template" >"$RUNDIR/$variant.caddyfile"
            ;;
        *)
            cat > "$file" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"
[backends.app]
kind = "worker"
command = "$PHP_WORKER_WRAPPER $ROOT/worker.php"
workers = $WORKERS
working_dir = "$ROOT"
max_requests = 0
checksum = "$(checksum_of "$variant")"
EOF
            ;;
    esac
}

# --- start/stop -------------------------------------------------------------
PID=""
RR_PID=""
FP_PID=""

stop_variant() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    PID=""
    # Match RoadRunner by its CONFIG PATH. Its argv is `./rr serve` when started
    # from its own directory, so a pkill on the binary matches nothing and the
    # worker survives, holding its port into the next variant. Found twice in
    # bench.sh.
    [ -n "$RR_PID" ] && kill "$RR_PID" 2>/dev/null
    pkill -f "$RUNDIR/rr.yaml" 2>/dev/null
    [ -n "$RR_PID" ] && wait "$RR_PID" 2>/dev/null
    RR_PID=""
    # FrankenPHP is Caddy, so it is matched the same way RoadRunner is and for the
    # same reason: its argv is `frankenphp run --config .../franken.caddyfile`, and
    # a pkill on the binary name is both too wide (it would match an unrelated
    # Caddy on this host) and too fragile. The stamped config path is unique to
    # this run. Killing it takes its worker threads with it, because they are
    # threads of that process rather than children.
    [ -n "$FP_PID" ] && kill "$FP_PID" 2>/dev/null
    # Matched by a wildcard rather than by the variant name, so the EXIT trap can
    # call this with no argument at all and still reap a FrankenPHP left behind by
    # an interrupted run. Only this arm ever has a `.caddyfile` in RUNDIR.
    pkill -f "$RUNDIR/.*[.]caddyfile" 2>/dev/null
    [ -n "$FP_PID" ] && wait "$FP_PID" 2>/dev/null
    FP_PID=""
}

# The warm arms' children are `php .../worker.php` and `php .../roadrunner-worker.php`,
# not php-cgi, so bench.sh's `-b` guard does not apply here. Matching the script path
# is unambiguous — no host service runs a worker from this checkout — and a survivor
# would hold a pipe and compete for cores in the next round, which is the leak this
# guard is for. `-ww` is load-bearing: without it the argv is truncated to the
# terminal width and the path is lost.
#
# The stamped Caddyfile path is matched as well, and that one is not about children:
# FrankenPHP's workers are THREADS of the Caddy process, so no descendant ever
# carries the worker script's path. A FrankenPHP left running by a failed teardown
# would be invisible to the two script paths above while still holding its port —
# and, worse, the next round's `wait_port` would then succeed against the OLD server
# and publish a measurement of a variant that was never started.
worker_pids() {
    # One line, deliberately: awk ends the pattern at a newline, so a `&& (` split
    # across lines is a syntax error, and awk's error goes to stderr while the
    # function still returns an empty list — which reads as "clean". That happened
    # on the first run of this arm and made the leak guard silently blind.
    ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" -v rundir="$RUNDIR" '
        $0 !~ /awk/ && $0 ~ (root "/worker[.]php|" root "/roadrunner-worker[.]php|" rundir "[.]caddyfile") { print $1 }'
}

count_workers() { worker_pids | wc -w | tr -d " "; }

guard_variant() {
    local variant="$1" n pids
    # The server's own Drop reaps its children; give it the moment it needs.
    sleep 0.5
    n="$(count_workers)"
    [ "$n" = "0" ] && { echo "  leak check [$variant]: clean"; return 0; }
    pids="$(worker_pids)"
    echo "  leak check [$variant]: $n worker(s) left behind: $(tr '\n' ' ' <<<"$pids")"
    kill $pids 2>/dev/null
    sleep 1
    n="$(count_workers)"
    if [ "$n" != "0" ]; then
        kill -9 $(worker_pids) 2>/dev/null
        sleep 1
        n="$(count_workers)"
        [ "$n" = "0" ] || { echo "  leak check [$variant]: FAILED - $n survived SIGKILL"; exit 1; }
    fi
    echo "  leak check [$variant]: cleared"
}

finish() {
    stop_variant
}
trap finish EXIT

wait_port() {
    local port="$1" i
    for i in $(seq 1 160); do
        curl -s -o /dev/null "http://127.0.0.1:$port/items" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

# Is anything already answering on a port this run is about to use?
#
# This is the one failure that corrupts a whole run without leaving a mark on any
# single cell. `wait_port` above succeeds against *whatever* is listening, so a server
# left behind by an interrupted run makes the next round's start-up look fine while the
# number that comes out belongs to a process this run did not start and cannot vouch
# for. It is not hypothetical: it produced a FrankenPHP row of 4,478 rps against a true
# 15,300 during the CPU-attribution work, and it was then caught again as a stray
# holding port 19900 across a logged run — which is why every run now refuses to begin
# on a port it does not own.
#
# The check is done once, up front, for all variants at once. Checking per-cell would
# not help: by the time a cell runs, the wrong server has already been measured.
port_is_free() {
    ! curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null
}

check_ports_free() {
    local v p busy=""
    for v in ${VARIANTS//,/ }; do
        p="$(port_of "$v")"
        port_is_free "$p" || busy="$busy $v($p)"
    done
    if [ -n "$busy" ]; then
        echo "FATAL: something is already answering on a port this run needs, so it"
        echo "       would be measured in place of the variant named:$busy"
        echo "       See what owns it:  ss -ltnp"
        echo "       Or kill every bench server:  pkill -f stoke-bench-run-ab"
        exit 1
    fi
}

# Answering 200 is not enough: an arm that serves the wrong page measures the
# wrong application, and this repository has already published a number for an
# nginx arm that was serving the front controller's SOURCE with a happy 200.
check_page() {
    local port="$1" path="$2" marker="$3" body code
    body="$(curl -sS --max-time 20 "http://127.0.0.1:$port$path" 2>/dev/null)"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$port$path" 2>/dev/null)"
    [ "$code" = "200" ] || { echo "  sanity FAILED $path: HTTP $code"; return 1; }
    case "$body" in
        *"$marker"*) return 0 ;;
    esac
    echo "  sanity FAILED $path: 200 but '$marker' is missing (${#body} bytes)"
    return 1
}

sanity() {
    local port="$1"
    check_page "$port" "/items" "Benchmark Item" || return 1
    check_page "$port" "/" "Azera" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Is this arm serving through a resident worker at all?
#
# A server that answers 200 with the right page and the right bytes can still be
# serving the wrong MODEL, and on this repository that has already published a number
# once — which is why `bench.sh` checks the body and not just the status. The
# FrankenPHP arm has the sharpest version of the trap, because there the
# misconfiguration is a DEFAULT rather than a typo: `php_server` runs a `worker` only
# where `match` says so, and its default is "requests for a .php file". Everything
# else is handed to the ordinary per-request PHP handler, which re-executes the front
# controller from scratch.
#
# Measured on this host, same binary, two Caddyfiles differing only by that one
# directive, `GET /items` at conc 32:
#
#     worker matched to `/*`    15,856 rps
#     no `match` (the default)     662 rps
#
# A 24x gap that no response can reveal: both return 200, both contain the page
# marker, both serve byte-identical bodies. The check is therefore a positive one
# rather than a smell test — the worker script writes a line the first time its
# request loop is actually asked to serve something, and if the line is missing the
# loop was never entered.
#
# A timing check was tried first and discarded, with the numbers: an unloaded request
# takes a median 1.26 ms through the worker and 2.61 ms through the cold path on this
# host, and the best-case cold (1.96 ms) overlaps the worst-case warm (1.35 ms). Any
# floor between them would be a coin flip, and the host is shared with other work.
# A thread count read out of the log was tried too and discarded for the same class of
# reason: both configurations start all 12 worker threads and both log all 12 reaching
# their loop. The worker is real in both cases; it is simply never asked to serve.
# ---------------------------------------------------------------------------
assert_worker_mode() {
    local variant="$1" log="$RUNDIR/$1.log" n
    case "$variant" in franken) ;; *) return 0 ;; esac
    n="$(grep -c 'served its first request' "$log" 2>/dev/null || true)"
    n="${n:-0}"
    if [ "$n" -lt 1 ]; then
        echo "  model check [franken]: FAILED - the worker loop was never entered, so"
        echo "  this arm served the COLD path. The Caddyfile's worker needs 'match /*';"
        echo "  without it php_server answers every request from the per-request handler"
        echo "  with a correct 200, and the arm measures a model it does not claim."
        return 1
    fi
    echo "  model check [franken]: resident, $n of $WORKERS worker thread(s) served a request"
    return 0
}

start_variant() {
    local variant="$1" port
    port="$(port_of "$variant")"
    case "$variant" in
        rr)
            ( cd "$ROOT" && exec "$RR" serve -c "$RUNDIR/rr.yaml" ) \
                >"$RUNDIR/$variant.log" 2>&1 &
            RR_PID=$!
            ;;
        franken)
            # `--config` and an explicit adapter, not a bare `Caddyfile` in the
            # working directory: the config lives beside the other variants' configs
            # and is named after this one, which is also how teardown finds it.
            "$FP" run --config "$RUNDIR/$variant.caddyfile" --adapter caddyfile \
                >"$RUNDIR/$variant.log" 2>&1 &
            FP_PID=$!
            ;;
        *)
            "$(binary_of "$variant")" serve -c "$RUNDIR/$variant.toml" \
                >"$RUNDIR/$variant.log" 2>&1 &
            PID=$!
            ;;
    esac
}

# ---------------------------------------------------------------------------
# One measured cell. The label travels into the TSV so a row is self-describing
# without a lookup table that can drift out of date.
# ---------------------------------------------------------------------------
run_cell() {
    local variant="$1" port="$2" ep="$3" conc="$4" round="$5" label="$6"
    local out rps p50 p99
    out="$(wrk -t"$conc" -c"$conc" -d"$DUR" --latency "http://127.0.0.1:$port$ep" 2>/dev/null)"
    rps="$(awk '/^Requests\/sec:/{print $2; exit}' <<<"$out")"
    p50="$(awk '/^[[:space:]]+50%/{print $2; exit}' <<<"$out")"
    p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' <<<"$out")"
    if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
        echo "    $ep conc $conc  FAILED (incomplete wrk output)"
        printf '%s\t%s\t%s\t%s\t%s\tFAIL\t?\t?\n' \
            "$variant" "$conc" "$round" "$ep" "$label" >>"$RESULTS"
        return 0
    fi
    printf "    r%-2s %-7s conc %3s  %10s rps  p50 %8s  p99 %8s\n" \
        "$round" "$ep" "$conc" "$rps" "$p50" "$p99"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$variant" "$conc" "$round" "$ep" "$label" "$rps" "$p50" "$p99" >>"$RESULTS"
}

label_of() {
    case "$1" in
        new-req) echo "stokehold worker (checksum required)" ;;
        new-opt) echo "stokehold worker (checksum optional)" ;;
        old-req) echo "stokehold worker (pre-crc32c-fix)" ;;
        rr) echo "roadrunner worker" ;;
        franken) echo "frankenphp worker (embedded php)" ;;
        *) echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " interleaved A/B: is the warm arm's lead still there?"
echo "=============================================================="
echo "  host:        $(nproc) cores, $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) MB"
echo "  php:         $(php -v | head -1)"
echo "  stokehold:   $($BIN version 2>/dev/null | head -1)"
echo "  new  binary: $(md5sum "$BIN" | cut -d' ' -f1)"
for v in ${VARIANTS//,/ }; do
    [ "$v" = "old-req" ] || [ "$v" = "old-opt" ] || continue
    [ -x "$BIN_OLD" ] && echo "  old  binary: $(md5sum "$BIN_OLD" | cut -d' ' -f1)  (pre-crc32c-fix)" \
        || fail "variant $v needs BIN_OLD at $BIN_OLD"
done
echo "  variants:    $VARIANTS"
echo "  rotation:    round r starts at variant r mod $(awk -F, '{print NF}' <<<"$VARIANTS")"
echo "  endpoints:   $ENDPOINTS"
echo "  concurrency: $CONC   duration: $DUR   rounds: $ROUNDS   workers: $WORKERS"
echo

for v in ${VARIANTS//,/ }; do
    write_config "$v"
    case "$v" in
        rr) echo "  $v -> $RUNDIR/$v.yaml  port $(port_of "$v")" ;;
        franken) echo "  $v -> $RUNDIR/$v.caddyfile  port $(port_of "$v")" ;;
        *) echo "  $v -> $RUNDIR/$v.toml  port $(port_of "$v")" ;;
    esac
done
echo

# The embedded runtime's identity, for the same reason the binaries' md5 sums are
# printed: the arm is only reproducible if it is the same build. `frankenphp
# version` reports its bundled PHP as well, which is the confound this arm carries
# against the host's PHP — printed here rather than buried in a log per round.
if [ -x "$FP" ]; then
    echo "  frankenphp:  $("$FP" version 2>/dev/null | head -1)"
else
    for v in ${VARIANTS//,/ }; do
        [ "$v" = franken ] && fail "variant franken needs FP at $FP"
    done
fi
echo

# Before the results file is truncated, so a run that refuses to start leaves the previous
# one's rows intact rather than emptying the file it is about to fail to fill.
check_ports_free

: >"$RESULTS"
printf 'variant\tconc\tround\tendpoint\tlabel\trps\tp50\tp99\n' >>"$RESULTS"

IFS=',' read -ra VS <<<"$VARIANTS"
N=${#VS[@]}
IFS=',' read -ra CS <<<"$CONC"
IFS=',' read -ra EPS <<<"$ENDPOINTS"

for round in $(seq 1 "$ROUNDS"); do
    echo "--------------------------------------------------------------"
    echo "ROUND $round of $ROUNDS"
    echo "--------------------------------------------------------------"
    for k in $(seq 0 $((N - 1))); do
        variant="${VS[$(( (k + round - 1) % N ))]}"
        port="$(port_of "$variant")"
        echo "  [$variant] starting on port $port"
        start_variant "$variant"
        if ! wait_port "$port" || ! sanity "$port" || ! assert_worker_mode "$variant"; then
            echo "  $variant NOT MEASURED this round:"; tail -12 "$RUNDIR/$variant.log" 2>/dev/null
            stop_variant
            guard_variant "$variant"
            continue
        fi
        # One warm-up per variant-round, not per cell: the pool reaches steady
        # state once, and paying for it twelve times would triple the run for
        # nothing. `max_requests = 0` means nothing recycles underneath it.
        wrk -t"$WORKERS" -c"$WORKERS" -d"$WARMUP" "http://127.0.0.1:$port/items" >/dev/null 2>&1
        for ep in "${EPS[@]}"; do
            for conc in "${CS[@]}"; do
                run_cell "$variant" "$port" "$ep" "$conc" "$round" "$(label_of "$variant")"
            done
        done
        stop_variant
        guard_variant "$variant"
    done
    echo
done

echo "=============================================================="
echo " raw rows: $RESULTS"
echo " $(wc -l <"$RESULTS") lines"
echo "=============================================================="
awk -F'\t' 'NR>1 && $6!="FAIL"{n++} END{print "  measured cells: " n}' "$RESULTS"
awk -F'\t' 'NR>1 && $6=="FAIL"{n++} END{print "  failed cells:   " n+0}' "$RESULTS"
