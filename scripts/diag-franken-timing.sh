#!/bin/bash
# What does the `match /*` trap actually look like in wall-clock terms, unloaded?
#
# This decides the sanity check: if a resident worker answers an unloaded request in
# ~1 ms and the per-request path takes ~30 ms, a timing floor separates them with
# margin. If they overlap, a floor is not a check and the guard has to be something
# else.
set -uo pipefail
FP=/home/competition/bin/frankenphp
A=/home/competition/workspace/stokehold-competition
R=/home/competition/fp-timing
rm -rf "$R"; mkdir -p "$R"

pkill -f "$R/.*[.]caddyfile" 2>/dev/null
sleep 1

sed -e "s#{{ROOT}}#$A#g" -e "s#{{PORT}}#18993#g" -e "s#{{WORKERS}}#12#g" \
    "$A/conf/frankenphp.caddyfile.template" > "$R/w.caddyfile"
sed -e "s#{{ROOT}}#$A#g" -e "s#{{PORT}}#18994#g" -e "s#{{WORKERS}}#12#g" -e "/match \/\*/d" \
    "$A/conf/frankenphp.caddyfile.template" > "$R/c.caddyfile"

cd "$R"
setsid "$FP" run --config "$R/w.caddyfile" --adapter caddyfile >"$R/w.log" 2>&1 &
setsid "$FP" run --config "$R/c.caddyfile" --adapter caddyfile >"$R/c.log" 2>&1 &
for i in $(seq 1 60); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:18993/items" 2>/dev/null &&
        curl -s -o /dev/null -m 1 "http://127.0.0.1:18994/items" 2>/dev/null && break
    sleep 0.5
done
sleep 2

for pair in "worker:18993" "cold:18994"; do
    name="${pair%%:*}"; port="${pair##*:}"
    echo "=== $name (port $port) ==="
    # Sequential and idle: nothing else is talking to this server, so this is the
    # cost of one request with no queue in front of it.
    times=""
    for i in $(seq 1 12); do
        t="$(curl -s -o /dev/null -w '%{time_total}' -m 20 "http://127.0.0.1:$port/items")"
        times="$times $t"
        sleep 0.2
    done
    echo "  seconds per unloaded request:$times"
    echo "$times" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '
        {a[NR]=$1}
        END { printf "  min %.5f  median %.5f  max %.5f  (n=%d)\n", a[1], a[int((NR+1)/2)], a[NR], NR }'
    echo
done

echo "=== ratio of medians ==="
m_w=$(for i in $(seq 1 9); do curl -s -o /dev/null -w '%{time_total}\n' -m 20 "http://127.0.0.1:18993/items"; done | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
m_c=$(for i in $(seq 1 9); do curl -s -o /dev/null -w '%{time_total}\n' -m 20 "http://127.0.0.1:18994/items"; done | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
echo "  worker $m_w   cold $m_c"
awk -v w="$m_w" -v c="$m_c" 'BEGIN{ printf "  cold/worker = %.1fx\n", c / w }'

pkill -f "$R/.*[.]caddyfile" 2>/dev/null
sleep 2
echo
echo "=== strays ==="
ps -eww -o args | grep '[f]rankenphp run' | head
