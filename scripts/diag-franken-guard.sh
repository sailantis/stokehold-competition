#!/bin/bash
# Does the model check actually discriminate? A guard that passes everything is
# worse than no guard, because it reads as evidence.
#
# Two throwaway copies of the worker script are used: one that serves through the
# worker loop (the real one) and one whose loop is never entered (the same script
# with `match` dropped from the Caddyfile). The check must pass the first and fail
# the second. No file in the checkout is modified.
set -uo pipefail
FP=/home/competition/bin/frankenphp
A=/home/competition/workspace/volucer-competition
R=/home/competition/fp-guard
PORT=18995
rm -rf "$R"; mkdir -p "$R"
pkill -f "$R/.*[.]caddyfile" 2>/dev/null
sleep 1

sed -e "s#{{ROOT}}#$A#g" -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#4#g" \
    "$A/conf/frankenphp.caddyfile.template" > "$R/worker.caddyfile"
sed -e "s#{{ROOT}}#$A#g" -e "s#{{PORT}}#$PORT#g" -e "s#{{WORKERS}}#4#g" -e "/match \/\*/d" \
    "$A/conf/frankenphp.caddyfile.template" > "$R/nomatch.caddyfile"

php -l "$A/frankenphp-worker.php" || exit 1

probe() {
    local cfg="$1" tag="$2"
    pkill -f "$R/.*[.]caddyfile" 2>/dev/null
    sleep 1
    : > "$R/$tag.log"
    ( cd "$R" && exec "$FP" run --config "$cfg" --adapter caddyfile ) >"$R/$tag.log" 2>&1 &
    local pid=$!
    for i in $(seq 1 60); do
        curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/items" 2>/dev/null && break
        sleep 0.5
    done
    curl -s -o /dev/null -m 10 "http://127.0.0.1:$PORT/items"
    sleep 0.5
    local n
    n="$(grep -c 'served its first request' "$R/$tag.log" 2>/dev/null || true)"
    echo "  [$tag] 'served its first request' lines: ${n:-0}   ->  guard would $([ "${n:-0}" -ge 1 ] && echo PASS || echo FAIL)"
    kill "$pid" 2>/dev/null
    pkill -f "$R/.*[.]caddyfile" 2>/dev/null
    sleep 1
}

echo "=== the guard must PASS the real configuration and FAIL the default ==="
probe "$R/worker.caddyfile" worker
probe "$R/nomatch.caddyfile" nomatch
echo
echo "=== strays ==="
ps -eww -o args | grep '[f]rankenphp run' | head
