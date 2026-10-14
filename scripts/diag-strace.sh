#!/bin/bash
# Which syscall owns the 40 ms?
#
# The wire trace shows php-cgi's trailing 1728-byte segment leaving 10 us after
# volucer's ACK arrives, and the ACK arriving 40 ms after the data. Two candidate
# mechanisms remain, and they need different fixes:
#
#   a) php-cgi never set TCP_NODELAY, so Nagle holds the trailing short segment until
#      the ACK arrives. Fix belongs to the sender; on volucer's side the mitigation
#      is to make the receiver ACK immediately (TCP_QUICKACK).
#   b) php-cgi set TCP_NODELAY and is blocked somewhere else, in which case Nagle is
#      not involved and the 40 ms has another owner.
#
# `fastcgi.c` line 1088 is the discriminator: php-cgi sets TCP_NODELAY only when the
# BEGIN_REQUEST carried FCGI_KEEP_CONN. volucer does send that flag, so (a) should
# be false — which is exactly why this is worth checking rather than assuming.
#
# Usage: bash diag-strace.sh

set -u

ROOT="${ROOT:-$HOME/workspace/volucer-competition}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
DIR="$(mktemp -d /tmp/diag-strace.XXXXXX)"
PHP_CGI="$(command -v php-cgi)"
PORT=19560
CGI_PORT=19900

cleanup() {
    [ -n "${PID:-}" ] && sudo kill "$PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

echo "=== kernel delayed-ACK knobs ==="
for k in net.ipv4.tcp_delack_min net.ipv4.tcp_quickack net.ipv4.tcp_nodelay net.ipv4.tcp_autocorking; do
    v="$(sysctl -n "$k" 2>/dev/null)" && echo "  $k = $v" || echo "  $k = (not present)"
done
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

# `-f` follows the fork into php-cgi; `-tt` gives absolute wall-clock seconds with
# microseconds, the same clock the tcpdump capture uses; `-T` appends how long each
# call took, which is what names the blocked one.
sudo strace -f -tt -T -s 40 -o "$DIR/strace.txt" \
    -e trace=socket,setsockopt,connect,sendto,recvfrom,sendmsg,recvmsg,shutdown,close \
    "$BIN" serve -c "$DIR/tcp.toml" > "$DIR/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.1
done
sleep 1

echo "=== 3 timed sequential requests, one reused client connection ==="
curl -s -o /dev/null -w '  request %{http_code}  %{time_total}s\n' \
    "http://127.0.0.1:$PORT/items" \
    "http://127.0.0.1:$PORT/items" \
    "http://127.0.0.1:$PORT/items"
sleep 1
sudo kill "$PID" 2>/dev/null
PID=""
sleep 0.5

echo
echo "=== does php-cgi set TCP_NODELAY? (SOL_TCP=6, TCP_NODELAY=1) ==="
grep -n 'setsockopt' "$DIR/strace.txt" | tail -20
echo
echo "  count of TCP_NODELAY by php-cgi: $(grep -c 'TCP_NODELAY' "$DIR/strace.txt" 2>/dev/null || echo 0)"
echo "  (if the trace prints numbers rather than names, TCP_NODELAY is 6,1,1,4)"

echo
echo "=== writes and reads with elapsed time, php-cgi side (fds after connect) ==="
# The interesting calls are the ones that took a long time, however they are named.
grep -E '<[0-9]+\.[0-9]{4}>' "$DIR/strace.txt" | sort -t'<' -k2 -rn | head -20

echo
echo "=== the socket calls with their timestamps ==="
grep -E 'setsockopt|sendto|recvfrom' "$DIR/strace.txt" | head -40

echo
echo "=== volucer log ==="
tail -5 "$DIR/server.log"
