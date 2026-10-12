#!/bin/bash
# Prove the mechanism, reversibly.
#
# The evidence so far: T is a flat 42.0 ms per request on /items over loopback TCP,
# U is 1.2 ms over a unix socket, TcpExtDelayedACKs is ~1 per request on T and
# exactly 0 on U, and the wire trace shows php-cgi's trailing 1728-byte segment
# leaving 10 us after stokehold's ACK arrives 40 ms late.
#
# That last number is the tell: 40 ms is the Linux delayed-ACK timer, and 6.8 gained a
# knob for exactly it. If lowering the timer collapses the 42 ms, the mechanism is the
# receiver's delayed ACK. Nothing else about the two arms changes, and the knob goes
# back afterwards.
#
# Usage: bash diag-delack.sh

set -u

ROOT="${ROOT:-$HOME/workspace/stokehold-competition}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
DIR="$(mktemp -d /tmp/diag-delack.XXXXXX)"
PHP_CGI="$(command -v php-cgi)"
PORT=19570
CGI_PORT=19950

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    wait 2>/dev/null
    # Never leave the host's TCP behaviour changed, however this exits.
    for kv in "$ORIG_DELACK" "$ORIG_ACKS" "$ORIG_AUTOCORK"; do
        sudo sysctl -w "$kv" >/dev/null 2>&1
    done
    rm -rf "$DIR"
    echo "--- knobs restored ---"
    for k in net.ipv4.tcp_delack_min net.ipv4.tcp_acks net.ipv4.tcp_autocorking; do
        printf '    %-30s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
    done
}
trap cleanup EXIT

# Read the originals into strings of the form key=value, for a faithful restore.
read_knob() { local k="$1" v; v="$(sysctl -n "$k" 2>/dev/null)"; [ -n "$v" ] && echo "$k=$v"; }
ORIG_DELACK="$(read_knob net.ipv4.tcp_delack_min)"
ORIG_ACKS="$(read_knob net.ipv4.tcp_acks)"
ORIG_AUTOCORK="$(read_knob net.ipv4.tcp_autocorking)"

echo "=== knobs before ==="
for k in net.ipv4.tcp_delack_min net.ipv4.tcp_acks net.ipv4.tcp_autocorking; do
    printf '    %-30s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
done
echo "  (tcp_delack_min is the minimum delayed-ACK time; 40 is Linux's default)"
echo

cat > "$DIR/php-cgi-bench" <<WRAPPER
#!/bin/sh
exec $PHP_CGI -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-cgi-bench"

cat > "$DIR/tcp.toml" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$PORT"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = 1
bind_host = "127.0.0.1"
base_port = $CGI_PORT
max_requests = 0
EOF

"$BIN" serve -c "$DIR/tcp.toml" > "$DIR/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.1
done

measure() {
    local label="$1"
    echo "  --- $label ---"
    php "$ROOT/scripts/latency.php" "http://127.0.0.1:$PORT" /items 300 3 "$label" "Benchmark Item" \
        | awk -F'\t' '{ printf "    run %s  median %8s ms  min %8s ms  p95 %8s ms\n", $2, $3, $5, $6 }'
}

measure "baseline (delack_min=40)"

echo
echo "=== net.ipv4.tcp_delack_min = 1 ==="
sudo sysctl -w net.ipv4.tcp_delack_min=1 >/dev/null
measure "delack_min=1"

echo
echo "=== net.ipv4.tcp_delack_min = 1 and tcp_autocorking = 0 ==="
sudo sysctl -w net.ipv4.tcp_autocorking=0 >/dev/null
measure "delack_min=1 autocorking=0"

echo
echo "=== restored to the original values ==="
[ -n "$ORIG_DELACK" ] && sudo sysctl -w "$ORIG_DELACK" >/dev/null
[ -n "$ORIG_ACKS" ] && sudo sysctl -w "$ORIG_ACKS" >/dev/null
[ -n "$ORIG_AUTOCORK" ] && sudo sysctl -w "$ORIG_AUTOCORK" >/dev/null
measure "restored (delack_min=40)"

echo
echo "=== TcpExt counters during the whole run ==="
nstat -az 2>/dev/null | grep -E 'DelayedACKs|DelayedACKLost|TCPAutoCorking' | head
