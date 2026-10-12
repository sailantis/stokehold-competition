#!/bin/bash
# Where does the server process's CPU actually go?
#
# `diag-split.sh` shows stokehold's HTTP front-end burning ~1.36x RoadRunner's
# CPU per request in the warm arm (206 us against 152). That is a fact about the
# server, not about PHP - the two arms run the same PHP and the same application
# - so the next question is which part of the front-end it is.
#
# A flat `perf` profile answers it directly, and it can tell apart the three
# candidates that a wall-clock reading cannot:
#
#   - allocator and free: a per-request allocation that the other server avoids
#   - the CGI environment build (`to_cgi`): one HashMap of ~15 CGI variables plus
#     a handful of String allocations, per request
#   - syscalls: pipe or socket write/read, and how many of them per request
#
# `--call-graph dwarf` is deliberately not used. It needs frame pointers or
# unwinding info that a Rust release build with default settings does not
# guarantee, and a wrong stack graph is worse than none. The flat profile with
# symbol names is enough to name the function, and `perf stat` alongside it
# counts the syscalls that the flat profile only hints at.
#
# Usage:
#   bash diag-profile.sh              # profile stokehold arm P for 8s at conc 32
#   ARM=T BIN=... bash diag-profile.sh
#   ARM=R bash diag-profile.sh        # RoadRunner, for the other side

set -u

ROOT="${ROOT:-$HOME/workspace/stokehold-competition}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
RR="${RR:-$HOME/bin/rr}"
ARM="${ARM:-P}"
CONC="${CONC:-32}"
DUR="${DUR:-8s}"
WORKERS="${WORKERS:-12}"
PORT=19790

PHP="$(command -v php)"
PHP_CGI="$(command -v php-cgi)"
DIR="$(mktemp -d /tmp/diag-prof.XXXXXX)"

cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
    pkill -f "$DIR/rr.yaml" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

cat > "$DIR/php-worker-bench" <<WRAPPER
#!/bin/sh
exec $PHP -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
cat > "$DIR/php-cgi-bench" <<WRAPPER
#!/bin/sh
exec $PHP_CGI -d opcache.enable_cli=1 -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$DIR/php-worker-bench" "$DIR/php-cgi-bench"

case "$ARM" in
    P|T)
        if [ "$ARM" = "P" ]; then
            cat > "$DIR/cfg.toml" <<EOF
default_backend = "app"
[server]
http = "127.0.0.1:$PORT"
document_root = "$ROOT/public"
[backends.app]
kind = "worker"
command = "$DIR/php-worker-bench $ROOT/worker.php"
workers = $WORKERS
working_dir = "$ROOT"
max_requests = 0
EOF
        else
            cat > "$DIR/cfg.toml" <<EOF
default_backend = "cgi"
[server]
http = "127.0.0.1:$PORT"
document_root = "$ROOT/public"
[backends.cgi]
kind = "spawn_cgi"
binary = "$DIR/php-cgi-bench"
workers = $WORKERS
bind_host = "127.0.0.1"
base_port = 19850
max_requests = 0
EOF
        fi
        "$BIN" serve -c "$DIR/cfg.toml" > "$DIR/server.log" 2>&1 &
        PID=$!
        ;;
    R)
        cat > "$DIR/rr.yaml" <<EOF
version: "3"
server:
  command: "$DIR/php-worker-bench $ROOT/roadrunner-worker.php"
  relay: pipes
http:
  address: "127.0.0.1:$PORT"
  pool:
    num_workers: $WORKERS
    max_jobs: 0
logs:
  mode: production
  level: warn
EOF
        ( cd "$ROOT" && "$RR" serve -c "$DIR/rr.yaml" > "$DIR/server.log" 2>&1 ) &
        PID=$!
        ;;
    *)
        echo "unknown ARM=$ARM" >&2; exit 1 ;;
esac

for _ in $(seq 1 200); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/items" 2>/dev/null && break
    sleep 0.25
done

echo "=============================================================="
echo " ARM $ARM, conc $CONC, ${DUR}s    server pid $PID"
echo "=============================================================="

# An unmeasured warm-up first, so the profile is steady state and not boot.
wrk -t"$CONC" -c"$CONC" -d3s "http://127.0.0.1:$PORT/items" >/dev/null 2>&1

# `perf stat` first: syscalls and context switches per request, which is where a
# per-request allocation or an extra read/write shows up as a count rather than
# as a symbol.
wrk -t"$CONC" -c"$CONC" -d"$DUR" "http://127.0.0.1:$PORT/items" > "$DIR/wrk.txt" 2>&1 &
WRK=$!
sleep 0.4
echo
echo "--- perf stat (syscalls, context switches) ---"
sudo perf stat -p "$PID" -e syscalls:sys_enter_read,syscalls:sys_enter_write,syscalls:sys_enter_futex,syscalls:sys_enter_mmap,context-switches,cpu-migrations -- sleep 6 2>&1 \
    | grep -vE '^\s*$|^#|Performance counter'
wait "$WRK" 2>/dev/null
RPS=$(awk '/^Requests\/sec:/{print $2; exit}' "$DIR/wrk.txt")
echo "  throughput during the run: ${RPS} rps"
[ -n "$RPS" ] && echo "  (divide the counts above by 6s x ${RPS} rps to get them per request)"

# Then the flat profile.
wrk -t"$CONC" -c"$CONC" -d"$DUR" "http://127.0.0.1:$PORT/items" >/dev/null 2>&1 &
WRK=$!
sleep 0.4
cd "$DIR" || exit 1
sudo perf record -F 1999 -p "$PID" -o "$DIR/perf.data" -- sleep 6 >/dev/null 2>&1
wait "$WRK" 2>/dev/null

echo
echo "--- perf report, flat (self time, >= 0.8%) ---"
sudo perf report --stdio --no-children --percent-limit 0.8 -i "$DIR/perf.data" 2>/dev/null \
    | grep -vE '^#|^\s*$'

echo
echo "--- how many symbols resolved? ---"
sudo perf report --stdio --no-children -i "$DIR/perf.data" 2>/dev/null \
    | grep -cE '^\s+[0-9]+\.[0-9]+%' || true
