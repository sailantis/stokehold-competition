#!/bin/bash
# Why is a saturated run only ~84% busy?
#
# A snapshot of `top` during a sweep shows twelve php-cgi children at ~72% each, so
# ~2 of 12 cores are idle while the run is at its throughput ceiling. Two very different
# explanations, and they call for different conclusions:
#
#   (a) the pool is the bottleneck — 12 single-threaded children that each block on
#       read/write cannot keep 12 cores busy, so raising `workers` would raise throughput;
#   (b) the *request path* is the bottleneck — stokehold's HTTP front-end or its pool
#       dispatch is saturated, so more children would add idle capacity, not requests.
#
# The decisive comparison is the same run at 12 and at 24 children. If throughput rises
# with the pool, it was (a). If it does not, the children were not the limit.
#
# It also reports the duty cycle directly: CPU time consumed by php-cgi per second of wall
# time, divided by the child count. A single-threaded worker that spends any of its request
# cycle blocked on a socket has a duty cycle below 1.0 by construction, and that is worth
# knowing as a property of the per-request model rather than as a defect.
#
# Usage: bash diag-cpu.sh

set -u

ROOT="${ROOT:-$HOME/workspace/stokehold-competition}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
DIR="$(mktemp -d /tmp/diag-cpu.XXXXXX)"
PHP_CGI="$(command -v php-cgi)"
PORT=19590
BASE=19400

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    [ -n "${WRKPID:-}" ] && kill "$WRKPID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

cat > "$DIR/php-cgi-bench" <<WRAPPER
#!/bin/sh
exec $PHP_CGI -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-cgi-bench"

make_config() {
    local workers="$1" port="$2" base="$3" file="$4"
    cat > "$file" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$port"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = $workers
bind_host = "127.0.0.1"
base_port = $base
max_requests = 0
EOF
}

# Total CPU jiffies of every process whose comm matches php-cgi, plus the server itself.
# Reading /proc/<pid>/stat is 14 fields before utime, and the comm field can contain
# spaces, so parse after the last ')'.
cpu_snapshot() {
    local total=0 pid comm
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ -r "$d/stat" ] || continue
        comm="$(awk '{print $2}' "$d/stat" 2>/dev/null)"
        case "$comm" in
            \(php-cgi*|\(stokehold*|\(php-fpm*)
                total=$(( total + $(awk '{print $14 + $15}' "$d/stat" 2>/dev/null || echo 0) ))
                ;;
        esac
    done
    echo "$total"
}

hz="$(getconf CLK_TCK)"
echo "CLK_TCK = $hz (jiffies per second per core)"

run_case() {
    local workers="$1" conc="$2" dur="${3:-5s}"
    local port=$((PORT + workers))
    local cfg="$DIR/cfg-$workers.toml"
    make_config "$workers" "$port" $((BASE + workers * 10)) "$cfg"

    "$BIN" serve -c "$cfg" > "$DIR/server-$workers.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:$port/items" && break
        sleep 0.1
    done

    # Steady state: let wrk run, then sample CPU over a window inside it.
    wrk -t"$conc" -c"$conc" -d"$dur" --latency "http://127.0.0.1:$port/items" \
        > "$DIR/wrk-$workers.txt" 2>&1 &
    WRKPID=$!
    sleep 1.5

    local before after
    before="$(cpu_snapshot)"
    sleep 3
    after="$(cpu_snapshot)"

    wait "$WRKPID" 2>/dev/null
    WRKPID=""

    local rps cores
    rps="$(awk '/^Requests\/sec:/{print $2}' "$DIR/wrk-$workers.txt")"
    # 3 seconds of wall time, converted from jiffies to cores.
    cores="$(awk -v d="$((after - before))" -v hz="$hz" 'BEGIN{printf "%.2f", d / hz / 3}')"
    printf "  workers %-3s conc %-3s  %9s rps  php-cgi+server %6s cores  (%s%% of 12)\n" \
        "$workers" "$conc" "$rps" "$cores" "$(awk -v c="$cores" 'BEGIN{printf "%.0f", c/12*100}')"

    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
    sleep 1
}

echo
echo "=== is the pool size the limit? (conc 32, 5s) ==="
for w in 12 24 36; do
    run_case "$w" 32
done

echo
echo "=== and at conc 16, where the client is not the limit ==="
for w in 12 24; do
    run_case "$w" 16
done

echo
echo "=== system busy/idle during a 12-worker conc-32 run, per one-second interval ==="
# /proc/stat is CUMULATIVE since boot, so a single read reports the machine's average
# load since it came up (which on this host is ~11% busy) and says nothing about the run
# in progress. Two reads one second apart, subtracted, are the interval's utilisation.
cfg="$DIR/cfg-idle.toml"
make_config 12 "$PORT" "$BASE" "$cfg"
"$BIN" serve -c "$cfg" > "$DIR/server-idle.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/items" && break
    sleep 0.1
done
wrk -t32 -c32 -d6s "http://127.0.0.1:$PORT/items" > "$DIR/wrk-idle.txt" 2>&1 &
WRKPID=$!
sleep 1.5
read_cpu() {
    awk '/^cpu /{ tot=0; for (i=2; i<=11; i++) tot+=$i; print tot, $5 }' /proc/stat
}
for i in 1 2 3; do
    read -r t0 i0 <<< "$(read_cpu)"
    sleep 1
    read -r t1 i1 <<< "$(read_cpu)"
    awk -v t0="$t0" -v i0="$i0" -v t1="$t1" -v i1="$i1" -v n="$i" \
        'BEGIN { dt = t1 - t0; di = i1 - i0;
                 printf "  second %d: busy %.1f%%  idle %.1f%%  (of 12 cores: %.2f busy)\n",
                        n, (dt-di)/dt*100, di/dt*100, (dt-di)/dt*12 }'
done
wait "$WRKPID" 2>/dev/null; WRKPID=""
awk '/^Requests\/sec:/{printf "  throughput: %s rps\n", $2}' "$DIR/wrk-idle.txt"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
