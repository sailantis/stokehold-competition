#!/bin/bash
# Who waits? Capture the FastCGI conversation on loopback and print the segment
# timeline, so the 40 ms gap can be attributed to a side rather than guessed at.
#
# The counters from the previous run already say the delay is a delayed ACK
# (TcpExtDelayedACKs ~= 1 per request on T, exactly 0 on U). What they do not say is
# which end is idle during the wait. Timestamps do.
#
# Usage: bash diag-wire.sh

set -u

ROOT="${ROOT:-$HOME/workspace/stokehold-competition}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
DIR="$(mktemp -d /tmp/diag-wire.XXXXXX)"
PHP_CGI="$(command -v php-cgi)"
PORT=19550
CGI_PORT=19800

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    [ -n "${TCPDUMP:-}" ] && kill "$TCPDUMP" 2>/dev/null
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
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
done

# Warm up so the capture contains steady-state requests only.
for _ in 1 2 3 4 5; do curl -s -o /dev/null "http://127.0.0.1:$PORT/items"; done

echo "=== capturing 4 sequential requests on a reused connection ==="
# tcpdump needs root; the host has passwordless sudo.
sudo rm -f /tmp/wire.txt
sudo tcpdump -i lo -nn --time-stamp-precision=micro -tt -s 96 \
    -w /tmp/wire.pcap "tcp port $CGI_PORT" > "$DIR/tcpdump.log" 2>&1 &
TCPDUMP=$!
sleep 1.5

curl -s -o /dev/null -w 'request %{http_code} in %{time_total}s\n' \
    "http://127.0.0.1:$PORT/items" \
    "http://127.0.0.1:$PORT/items" \
    "http://127.0.0.1:$PORT/items" \
    "http://127.0.0.1:$PORT/items"

sleep 1
sudo kill "$TCPDUMP" 2>/dev/null
TCPDUMP=""
sleep 0.5

echo
echo "=== segment timeline (relative seconds, microsecond precision) ==="
echo "    a 127.0.0.1.<ephemeral> -> 127.0.0.1.$CGI_PORT   is stokehold sending to php-cgi"
echo "    a 127.0.0.1.$CGI_PORT -> 127.0.0.1.<ephemeral>   is php-cgi sending to stokehold"
echo
sudo tcpdump -r /tmp/wire.pcap -nn -tt 2>/dev/null | awk '
{
    # tcpdump -tt gives absolute epoch seconds with microseconds.
    t = $1 + 0
    if (first == 0) first = t
    dir = ($3 ~ /^127\.0\.0\.1\.'"$CGI_PORT"'$/) ? "cgi -> stoke" : "stoke -> cgi"
    flags = ""
    for (i = 5; i <= NF; i++) flags = flags " " $i
    printf "%10.6f  %-13s len %-5s%s\n", t - first, dir, $NF ~ /^length/ ? $NF : "", flags
}' | head -60

echo
echo "=== same, with gaps over 5 ms flagged ==="
sudo tcpdump -r /tmp/wire.pcap -nn -tt 2>/dev/null | awk '
{
    t = $1 + 0
    if (prev > 0) {
        gap = (t - prev) * 1000
        if (gap >= 5) printf "  >>> gap of %8.3f ms before: %s\n", gap, $0
    }
    prev = t
}' | head -40

sudo rm -f /tmp/wire.pcap
echo
echo "=== stokehold log ==="
tail -20 "$DIR/server.log"
