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
#
# `rr` is the control and the reason this is an A/B and not a trend: it shares no
# code with any other variant, so a round in which every stokehold variant moved
# but `rr` did not is a round in which stokehold moved, and a round in which both
# moved together is the host.
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
set -uo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
BIN_OLD="${BIN_OLD:-$HOME/stoke-bench-nocrc/target/release/stokehold}"
RUNDIR="${RUNDIR:-$HOME/stoke-bench-run-ab}"
RR="${RR:-$HOME/bin/rr}"
VARIANTS="${VARIANTS:-new-req,new-opt,old-req,rr}"
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
}

# The warm arms' children are `php .../worker.php` and `php .../roadrunner-worker.php`,
# not php-cgi, so bench.sh's `-b` guard does not apply here. Matching the script path
# is unambiguous — no host service runs a worker from this checkout — and a survivor
# would hold a pipe and compete for cores in the next round, which is the leak this
# guard is for. `-ww` is load-bearing: without it the argv is truncated to the
# terminal width and the path is lost.
worker_pids() {
    ps -eww -o pid=,args= 2>/dev/null | awk -v root="$ROOT" '
        $0 !~ /awk/ && index($0, root "/worker.php") + index($0, root "/roadrunner-worker.php") > 0 {
            print $1
        }'
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

start_variant() {
    local variant="$1" port
    port="$(port_of "$variant")"
    case "$variant" in
        rr)
            ( cd "$ROOT" && exec "$RR" serve -c "$RUNDIR/rr.yaml" ) \
                >"$RUNDIR/$variant.log" 2>&1 &
            RR_PID=$!
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
    echo "  $v -> $( [ "$v" = rr ] && echo "$RUNDIR/$v.yaml" || echo "$RUNDIR/$v.toml" )  port $(port_of "$v")"
done
echo

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
        if ! wait_port "$port" || ! sanity "$port"; then
            echo "  $variant NOT MEASURED this round:"; tail -5 "$RUNDIR/$variant.log" 2>/dev/null
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
