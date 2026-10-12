#!/bin/bash
# A focused diagnostic: is ARM T's collapse on /items a property of loopback TCP,
# or a property of how the harness drives it?
#
# The question comes from the sweep, where T measured 198-283 rps on /items while U
# measured 671-8118 on the same route with the same model and the same SAPI. Two
# candidate explanations are tested here:
#
#   1. The transport itself is slow for a ~12 KB response.
#   2. The harness's wrk invocation (-t$c -c$c) gives concurrency == threads, and at
#      low -c that is a single connection pinning a single slot. That is a real
#      measurement of one slot, not of the pool.
#
# This script drives T and U identically, sequentially, and reports TCP-level
# counters alongside, so a transport problem and a scheduling artifact can be told
# apart rather than argued about.
#
# Usage: bash diag-tcp.sh [iterations] [runs]

set -u

ITERS="${1:-2000}"
RUNS="${2:-5}"

ROOT="${ROOT:-$HOME/workspace/stokehold-competition}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
DIR="$(mktemp -d /tmp/diag-tcp.XXXXXX)"
PHP_CGI="$(command -v php-cgi)"
PORT_T=19500
PORT_U=19502

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
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

cat > "$DIR/tcp.toml" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$PORT_T"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = 1
bind_host = "127.0.0.1"
base_port = 19600
max_requests = 0
EOF

cat > "$DIR/unix.toml" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$PORT_U"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = 1
socket = "unix:$DIR/sock"
max_requests = 0
EOF

# TcpExt counters that would show a delayed-ACK / retransmit / RST problem. Sampled
# as a delta around each arm rather than read absolutely, because the host has other
# traffic and a cumulative counter says nothing on its own.
snap() {
    nstat -az 2>/dev/null | awk '$1 ~ /^(TcpExtDelayedACK|TcpExtTCPDelayedACK|TcpRetransSegs|TcpExtTCPSlowStartRetrans|TcpExtTCPTimeouts|TcpExtListenDrops|TcpExtTCPBacklogDrop|TcpOutSegs|TcpInSegs|TcpExtDelayedACKLost|TcpExtTCPRcvCoalesce|TcpExtTCPPureAcks|TcpExtTCPHPHits)/ {print $1, $2}'
}

report() {
    local label="$1" ep="$2"
    echo "  --- $label $ep: sequential, $RUNS x $ITERS ---"
    php "$ROOT/scripts/latency.php" "http://127.0.0.1:$3" "$ep" "$ITERS" "$RUNS" "$label" "Benchmark Item" 2>&1
}

run_arm() {
    local name="$1" config="$2" port="$3"
    "$BIN" serve -c "$config" > "$DIR/$name.log" 2>&1 &
    PID=$!
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:$port/" && break
        sleep 0.1
    done

    local before after
    before="$(snap)"
    report "$name" /items "$port"
    after="$(snap)"

    echo "  --- $name TCP counter delta ---"
    join <(echo "$before") <(echo "$after") | awk '{ printf "    %-28s %s\n", $1, $3-$2 }'
    echo "  --- $name sockets while serving (second sample) ---"
    ss -tin "sport = :$port or dport >= 19600" 2>/dev/null | head -12

    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
    sleep 1
}

echo "=== /items, one slot, sequential ==="
run_arm "T tcp"  "$DIR/tcp.toml"  "$PORT_T"
run_arm "U unix" "$DIR/unix.toml" "$PORT_U"

echo
echo "=== both again, reversed order, to rule out warm-up drift ==="
run_arm "U unix" "$DIR/unix.toml" "$PORT_U"
run_arm "T tcp"  "$DIR/tcp.toml"  "$PORT_T"

echo
echo "=== T with 12 slots, sequential: does the single-slot theory hold? ==="
# Same transport, same response size, twelve slots instead of one. If loopback TCP
# were the cause, twelve of them would be worse; if the sweep's 1-connection shape
# were the cause, sequential latency through a twelve-slot pool should look like the
# one-slot number, because only one slot is ever busy.
sed -i "s/^workers = 1/workers = 12/" "$DIR/tcp.toml"
sed -i "s/^base_port = 19600/base_port = 19700/" "$DIR/tcp.toml"
run_arm "T tcp x12" "$DIR/tcp.toml" "$PORT_T"
