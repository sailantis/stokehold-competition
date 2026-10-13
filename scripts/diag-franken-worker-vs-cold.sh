#!/bin/bash
# Two questions at once.
#
# 1. Does FrankenPHP's worker mode actually help, or is the embedded runtime so
#    fast that booting per request costs nothing? This is the same warm-vs-cold
#    question the repository asks of every other server, asked of the one server
#    that embeds PHP.
#
# 2. Does the harness's `match /*` guard actually catch the misconfiguration it
#    exists for? If a config with no `match` produces the same throughput as one
#    with it, the guard is theatre and the arm has been measuring nothing.
#
# Both are measured by running the same binary twice with two configs that differ
# ONLY in whether the worker is matched to every path.
set -uo pipefail
FP=/home/competition/bin/frankenphp
ROOT=/home/competition/workspace/stokehold-competition
RUNDIR=/home/competition/fp-worker-vs-cold
PORT=18992
rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"

# --- config A: the arm as the harness stamps it (worker matched to everything) ---
sed -e "s#{{ROOT}}#$ROOT#g" -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#12#g" \
    "$ROOT/conf/frankenphp.caddyfile.template" > "$RUNDIR/worker.caddyfile"

# --- config B: the same server with NO `match`, i.e. the default -----------------
# `php_server` with a worker but no match runs the worker only where the path ends
# in .php; every other path is looked up on disk, not found, and handed to the
# ordinary PHP handler. Same binary, same worker script, same thread count.
sed -e "s#{{ROOT}}#$ROOT#g" -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#12#g" \
    -e "/match \/\*/d" \
    "$ROOT/conf/frankenphp.caddyfile.template" > "$RUNDIR/nomatch.caddyfile"

run_one() {
    local name="$1" cfg="$2"
    pkill -f "$RUNDIR/.*[.]caddyfile" 2>/dev/null
    sleep 1
    : > "$RUNDIR/$name.log"
    ( cd "$RUNDIR" && exec "$FP" run --config "$cfg" --adapter caddyfile ) \
        >"$RUNDIR/$name.log" 2>&1 &
    local pid=$!
    for i in $(seq 1 60); do
        curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/items" 2>/dev/null && break
        sleep 0.5
    done
    local code body
    code="$(curl -s -o "$RUNDIR/$name.html" -w '%{http_code}' -m 10 "http://127.0.0.1:$PORT/items")"
    body="$(grep -c 'Benchmark Item' "$RUNDIR/$name.html" 2>/dev/null || true)"
    local wcount
    wcount="$(grep -c 'frankenphp-worker' "$RUNDIR/$name.log" 2>/dev/null || true)"
    echo "  [$name] http $code, marker lines $body, worker threads reporting in: ${wcount:-0}"

    wrk -t12 -c12 -d3s "http://127.0.0.1:$PORT/items" >/dev/null 2>&1
    for c in 8 16 32; do
        out="$(wrk -t"$c" -c"$c" -d5s --latency "http://127.0.0.1:$PORT/items" 2>/dev/null)"
        rps="$(awk '/^Requests\/sec:/{print $2; exit}' <<<"$out")"
        p99="$(awk '/^[[:space:]]+99%/{print $2; exit}' <<<"$out")"
        printf "    conc %-3s  %10s rps  p99 %8s\n" "$c" "$rps" "$p99"
    done
    kill "$pid" 2>/dev/null
    pkill -f "$RUNDIR/.*[.]caddyfile" 2>/dev/null
    sleep 1
}

echo "=== A: worker matched to every path (what the harness stamps) ==="
run_one worker "$RUNDIR/worker.caddyfile"
echo
echo "=== B: same binary, worker NOT matched (php_server default) ==="
run_one nomatch "$RUNDIR/nomatch.caddyfile"
echo
echo "=== strays ==="
ps -eww -o pid,args | awk '/[f]rankenphp|fp-worker-vs-cold/' | grep -v ' awk ' | head
