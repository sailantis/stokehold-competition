#!/bin/bash
# Five ways to serve one page, on one machine, measured the same way.
#
#   P  stokehold + resident worker     warm framework, pipe
#   T  stokehold + spawn_cgi (TCP)     cold framework, loopback TCP
#   U  stokehold + spawn_cgi (unix)    cold framework, unix socket
#   R  RoadRunner + resident worker    warm framework, pipe
#   F  nginx + php-fpm                 cold framework, unix socket
#
# The matrix is built so each pair isolates one variable:
#
#   T vs U   transport, same server / model / SAPI
#   F vs T,U server, same model / transport kind
#   P vs R   server, same model / transport
#   P vs T,U the deployment model, across transports
#
# One confound is stated rather than hidden: P is both warm AND piped, so P-vs-T/U
# mixes model with transport. The transport question is answered by T vs U, where
# the model is held equal, and the model question by P vs T/U, which is what the
# repository exists to ask. Hazard 23 in the stokehold plan already measured pipe
# and TCP as identical to concurrency 8 on a trivial handler.
#
# Usage:
#   bash bench.sh                          # every arm, both endpoints
#   ARMS=P,T,U bash bench.sh               # a subset
#   CONC=1,8,32 DUR=10s REPEAT=3 bash bench.sh
#   ENDPOINTS=/items bash bench.sh         # the ORM page only
#
# Environment:
#   BIN          stokehold release binary      (default ~/stoke-bench/target/release/stokehold)
#   ROOT         this checkout                 (default the script's parent directory)
#   RUNDIR       scratch + results             (default ~/stoke-bench-run)
#   RR           RoadRunner binary             (default ~/bin/rr)
set -uo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$SCRIPT_DIR")}"
BIN="${BIN:-$HOME/stoke-bench/target/release/stokehold}"
RUNDIR="${RUNDIR:-$HOME/stoke-bench-run}"
RR="${RR:-$HOME/bin/rr}"
ARMS="${ARMS:-P,T,U,R,F}"
CONC="${CONC:-1,4,8,16,32}"
DUR="${DUR:-5s}"
REPEAT="${REPEAT:-1}"
ENDPOINTS="${ENDPOINTS:-/,/items}"
SKIP_FPM="${SKIP_FPM:-0}"
# Sequential per-request latency, the published methodology. Runs after the sweep
# against the same servers. Set to 0 to skip (it adds about a minute per arm).
LATENCY="${LATENCY:-1}"
LAT_ITERS="${LAT_ITERS:-1000}"
LAT_RUNS="${LAT_RUNS:-10}"

PHP_CGI="$(command -v php-cgi || true)"
PHP_FPM_BIN="$(command -v php-fpm8.3 || command -v php-fpm || true)"
# The systemd unit is not always named after the binary: Debian/Ubuntu ship
# `php8.3-fpm.service` for `/usr/sbin/php-fpm8.3`. Resolve it rather than
# guessing, so a restart that fails is reported as a restart failure instead of
# being mistaken for a broken configuration.
FPM_SERVICE=""
for unit in php8.3-fpm php-fpm php-fpm8.3; do
    if systemctl list-unit-files "$unit.service" >/dev/null 2>&1 &&
        systemctl list-unit-files "$unit.service" 2>/dev/null | grep -q "^$unit.service"; then
        FPM_SERVICE="$unit"
        break
    fi
done
[ -n "$FPM_SERVICE" ] || FPM_SERVICE="php8.3-fpm"

mkdir -p "$RUNDIR"
SOCKET_DIR="$RUNDIR/sockets"
rm -rf "$SOCKET_DIR"
mkdir -p "$SOCKET_DIR"
# 0777 because php-fpm runs as www-data and nginx has to reach the same socket.
chmod 0777 "$SOCKET_DIR"

BASE_PORT="${BASE_PORT:-18400}"
CGI_TCP_BASE="${CGI_TCP_BASE:-19300}"
FPM_SOCKET="$SOCKET_DIR/fpm.sock"
FPM_POOL_CONF="/etc/php/8.3/fpm/pool.d/bench-stokehold.conf"
NGINX_CONF="/etc/nginx/conf.d/bench-stokehold.conf"
RESULTS="$RUNDIR/results.tsv"
LATENCY_RESULTS="$RUNDIR/latency.tsv"

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -x "$BIN" ] || fail "no stokehold binary at $BIN (build it, or set BIN)"
[ -f "$ROOT/composer.json" ] || fail "no checkout at $ROOT (set ROOT)"
[ -d "$ROOT/vendor" ] || fail "$ROOT/vendor is missing - run: composer install"
[ -f "$ROOT/data/bench.sqlite" ] || fail "$ROOT/data/bench.sqlite is missing - run: php seed.php"
[ -n "$PHP_CGI" ] || fail "no php-cgi on PATH"

# ---------------------------------------------------------------------------
# The fair php-cgi.
#
# php-cgi as installed is NOT configured like the php-fpm pool, and the difference
# decides the measurement rather than the deployment model:
#
#   opcache.enable_cli = Off   php-cgi reads this flag, php-fpm does not. Off
#                              means every PHP file is recompiled per request.
#   xdebug.mode = develop      on for php-cgi, explicitly off in the bench pool.
#
# On a small app these are nearly free, which is why the azera cold arms matched
# (409 vs 400 rps) and it was easy to miss. On Laravel - hundreds of files - it is
# ruinous: an unwrapped cold arm measured 16.6 rps against php-fpm's 49, a 3x gap
# with nothing to do with the server. The wrapper gives php-cgi the settings the
# FPM pool uses, so T/U-vs-F is a difference of server, not of ini.
#
# It is a shell script rather than a `-d` list because stokehold runs the
# configured command through its own tokenizer, not through a shell.
# ---------------------------------------------------------------------------
PHP_CGI_WRAPPER="$RUNDIR/php-cgi-bench"
cat > "$PHP_CGI_WRAPPER" <<WRAPPER
#!/bin/sh
exec $PHP_CGI -d opcache.enable_cli=1 \\
    -d opcache.validate_timestamps=0 \\
    -d xdebug.mode=off \\
    -d memory_limit=512M "\$@"
WRAPPER
chmod +x "$PHP_CGI_WRAPPER"

stamp() {
    # stamp <template> <output> [ more sed args... ]
    local template="$1" output="$2"
    shift 2
    sed -e "s#{{ROOT}}#$ROOT#g" \
        -e "s#{{PHP_CGI}}#$PHP_CGI_WRAPPER#g" \
        -e "s#{{SOCKET_DIR}}#$SOCKET_DIR#g" \
        -e "s#{{SOCKET}}#$FPM_SOCKET#g" \
        -e "s#{{CGI_TCP_BASE}}#$CGI_TCP_BASE#g" \
        -e "s#{{USER}}#$(id -un)#g" \
        -e "s#{{GROUP}}#$(id -gn)#g" \
        "$@" "$template" > "$output"
}

# --- stamp the stokehold + RoadRunner configs ------------------------------
stamp "$ROOT/conf/stoke-pipe.toml.template"     "$RUNDIR/stoke-pipe.toml"     -e "s#{{PORT}}#$((BASE_PORT + 0))#g"
stamp "$ROOT/conf/stoke-cgi-tcp.toml.template"  "$RUNDIR/stoke-cgi-tcp.toml"  -e "s#{{PORT}}#$((BASE_PORT + 1))#g" -e "s#{{BASE_PORT}}#$CGI_TCP_BASE#g"
stamp "$ROOT/conf/stoke-cgi-unix.toml.template" "$RUNDIR/stoke-cgi-unix.toml" -e "s#{{PORT}}#$((BASE_PORT + 2))#g"
stamp "$ROOT/conf/roadrunner.yaml.template"     "$RUNDIR/rr.yaml"             -e "s#{{PORT}}#$((BASE_PORT + 3))#g"

ARM_PORT_P=$((BASE_PORT + 0))
ARM_PORT_T=$((BASE_PORT + 1))
ARM_PORT_U=$((BASE_PORT + 2))
ARM_PORT_R=$((BASE_PORT + 3))
ARM_PORT_F=$((BASE_PORT + 4))

PID=""
RR_PID=""
# Two different jobs, deliberately not one function.
#
# `stop_arm` runs BETWEEN arms and only kills that arm's processes.
#
# `finish` runs ONCE, from the EXIT trap, and additionally tears the FPM
# deployment down. Conflating them was a real bug: running the FPM teardown after
# every arm deleted the pool and vhost set up at the start, so ARM F — the last
# one — found no nginx listening on its port and was never measured. The FPM
# configuration is provisioned once for the whole run and must survive every arm.
#
# `finish` being in the trap matters for a different reason: an interrupted run
# that skips it leaves a pool file behind that takes the HOST's php-fpm down for
# every other user of the machine. Found by interrupting a run and finding
# php-fpm stuck in `activating (auto-restart)` with no socket.
stop_arm() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$PID" ] && wait "$PID" 2>/dev/null
    PID=""
    # Match RoadRunner by its CONFIG PATH, never by its binary path: its argv is
    # "./rr serve" when started from its own directory, so a pkill on the resolved
    # binary silently matches nothing and the worker survives, holding its port and
    # distorting the next run. Found twice.
    [ -n "$RR_PID" ] && kill "$RR_PID" 2>/dev/null
    pkill -f "$RUNDIR/rr.yaml" 2>/dev/null
    [ -n "$RR_PID" ] && wait "$RR_PID" 2>/dev/null
    RR_PID=""
}

finish() {
    stop_arm
    teardown_fpm
}
trap finish EXIT

wait_port() {
    for _ in $(seq 1 160); do
        curl -s -o /dev/null "http://127.0.0.1:$1/" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

# --- one request that must succeed, or the arm is not measured --------------
#
# A server that starts but answers 500 would otherwise publish a real-looking
# throughput number for an arm that never ran the application. Both the status and
# a marker from the rendered page are checked, so "wrong page" fails too — which is
# not hypothetical: an nginx `try_files` mistake made this arm serve the front
# controller's SOURCE with a 200, and only reading the body caught it.
#
# Both endpoints the run measures are checked, because the markers differ: `/items`
# renders rows and `/` does not.
check_page() {
    local port="$1" path="$2" marker="$3"
    local body code
    body="$(curl -sS --max-time 20 "http://127.0.0.1:$port$path" 2>/dev/null)"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$port$path" 2>/dev/null)"
    if [ "$code" != "200" ]; then
        echo "  sanity FAILED $path: HTTP $code"
        [ -n "$body" ] && echo "  body: $(echo "$body" | head -c 200)"
        return 1
    fi
    case "$body" in
        *"$marker"*) return 0 ;;
        "$body"*"<?php"*)
            # The specific mistake worth naming, because the status is a happy 200.
            echo "  sanity FAILED $path: got PHP SOURCE, not a response (nginx served the file)"
            return 1
            ;;
        *) echo "  sanity FAILED $path: 200 but '${marker}' is missing (${#body} bytes)"
           echo "  body: $(echo "$body" | head -c 200)"
           return 1 ;;
    esac
}

sanity() {
    local port="$1" label="$2"
    check_page "$port" "/items" "Benchmark Item" || return 1
    check_page "$port" "/" "Azera" || return 1
    return 0
}

run_client() {
    local port="$1" label="$2" arm="$3"
    local url="http://127.0.0.1:$port"
    IFS=',' read -ra CS <<< "$CONC"
    for ep in ${ENDPOINTS//,/ }; do
        for c in "${CS[@]}"; do
            for rep in $(seq 1 "$REPEAT"); do
                out=$(wrk -t"$c" -c"$c" -d"$DUR" --latency "$url$ep" 2>/dev/null)
                # `exit` after the first match, and the percentile patterns are
                # anchored to a leading percentage: without both, a second matching
                # line is concatenated into the field, and that field is written
                # into a TAB-separated row — so an embedded newline silently splits
                # one measurement into two broken rows. Found by reading a summary
                # whose arm column contained "3.77ms".
                rps=$(echo "$out" | awk '/^Requests\/sec:/ {print $2; exit}')
                p50=$(echo "$out" | awk '/^[[:space:]]+50%/ {print $2; exit}')
                p99=$(echo "$out" | awk '/^[[:space:]]+99%/ {print $2; exit}')
                if [ -z "$rps" ] || [ -z "$p50" ] || [ -z "$p99" ]; then
                    echo "  $ep conc $c rep $rep  FAILED (incomplete wrk output)"
                    printf '%s\t%s\t%s\t%s\t%s\tFAIL\t?\t?\n' "$arm" "$c" "$rep" "$ep" "$label" >> "$RESULTS"
                    continue
                fi
                printf "  %-8s conc %3s rep %s  %10s rps  p50 %8s  p99 %8s\n" \
                    "$ep" "$c" "$rep" "$rps" "$p50" "$p99"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$arm" "$c" "$rep" "$ep" "$label" "$rps" "$p50" "$p99" >> "$RESULTS"
            done
        done
    done
}

# Sequential, one connection, hrtime() per request — the methodology the published
# 3.1x figure came from, and a different question from the sweep above. A 12-slot
# server at concurrency 1 has 11 idle slots, so a cell here is the cost of ONE
# request; the sweep is the behaviour of a busy pool. Reporting only the sweep is
# what let this project compare its numbers against published latency ratios without
# noticing it was measuring something else.
run_latency() {
    local port="$1" label="$2" arm="$3"
    [ "$LATENCY" = "1" ] || return 0
    for ep in ${ENDPOINTS//,/ }; do
        # The marker differs per endpoint, and the probe aborts rather than reporting
        # a number when it is missing. `/` renders no item rows; `/items` does.
        local marker="Azera"
        case "$ep" in
            /items*|*/items*) marker="Benchmark Item" ;;
        esac
        echo "  --- latency ($ep, $LAT_RUNS x $LAT_ITERS sequential) ---"
        php "$SCRIPT_DIR/latency.php" "http://127.0.0.1:$port" "$ep" \
            "$LAT_ITERS" "$LAT_RUNS" "$label" "$marker" 2>&1 | while IFS=$'\t' read -r l run med mean min p95 conn st; do
            # The data's first field is the LABEL, which contains a space, so it must
            # not be pattern-matched against a URL. Discriminate on the second field
            # instead: a run number is data, anything else is a diagnostic line.
            case "$run" in
                '' | *[!0-9]*) echo "    $l $run $med" ; continue ;;
            esac
            printf "    run %-2s  median %7s ms  mean %7s ms  min %7s ms  p95 %7s ms (connect %s ms)\n" \
                "$run" "$med" "$mean" "$min" "$p95" "$conn"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$arm" "seq" "$run" "$ep" "$label" "$med" "$min" "$p95" "$conn" >> "$LATENCY_RESULTS"
        done
    done
}

start_stokehold() {
    "$BIN" serve -c "$1" >"$RUNDIR/server-$2.log" 2>&1 &
    PID=$!
}

# ---------------------------------------------------------------------------
# ARM F setup: an FPM pool and an nginx vhost, written where the system expects
# them. Both are named for this repository so they cannot collide with a real
# deployment's configuration, and both are removed at the end.
# ---------------------------------------------------------------------------
fpm_available=1
# xdebug is loaded by default in this PHP build and costs the FPM arm 3.1x, and an
# ini setting cannot switch it off: `php_admin_value[xdebug.mode] = off` makes the
# value come back EMPTY while leaving the extension loaded (verified with a probe
# that prints ini_get('xdebug.mode') from inside the pool: 'off' -> empty, absent ->
# 'develop', and both keep it loaded). So the conf.d file is moved aside for the run.
XDEBUG_FPM_INI=""
XDEBUG_MOVED=""
disable_fpm_xdebug() {
    XDEBUG_FPM_INI="$(ls /etc/php/*/fpm/conf.d/*xdebug*.ini 2>/dev/null | head -1)"
    [ -n "$XDEBUG_FPM_INI" ] || { echo "  (no xdebug ini for php-fpm: nothing to disable)"; return 0; }
    XDEBUG_MOVED="/tmp/$(basename "$XDEBUG_FPM_INI").bench-disabled"
    if sudo mv "$XDEBUG_FPM_INI" "$XDEBUG_MOVED" 2>/dev/null; then
        echo "  disabled php-fpm xdebug: $XDEBUG_FPM_INI moved aside"
    else
        echo "  WARNING: could not disable xdebug for php-fpm; the FPM arm will be ~3x low"
        XDEBUG_FPM_INI=""
    fi
}
restore_fpm_xdebug() {
    [ -n "$XDEBUG_FPM_INI" ] && [ -n "$XDEBUG_MOVED" ] || return 0
    sudo mv "$XDEBUG_MOVED" "$XDEBUG_FPM_INI" 2>/dev/null
    XDEBUG_FPM_INI=""
    XDEBUG_MOVED=""
}

setup_fpm() {
    if [ "$SKIP_FPM" = "1" ]; then fpm_available=0; return 0; fi
    if [ -z "$PHP_FPM_BIN" ] || ! command -v nginx >/dev/null 2>&1; then
        echo "FPM arm skipped: no php-fpm or nginx installed"; fpm_available=0; return 0
    fi
    if ! sudo -n true 2>/dev/null; then
        echo "FPM arm skipped: no passwordless sudo to write the pool and vhost"
        fpm_available=0; return 0
    fi

    disable_fpm_xdebug
    stamp "$ROOT/conf/fpm-pool.conf.template" "$RUNDIR/fpm-pool.conf"
    stamp "$ROOT/conf/nginx-vhost.conf.template" "$RUNDIR/nginx-vhost.conf" -e "s#{{PORT}}#$ARM_PORT_F#g"

    # Prove the pool loads before touching the running service: a pool file the
    # parser rejects takes php-fpm down entirely, so `restart` would fail with a
    # vague systemd message instead of the line that is wrong. `php-fpm -t` parses
    # every pool in pool.d, so this is the whole configuration, not just this file.
    sudo cp "$RUNDIR/fpm-pool.conf" "$FPM_POOL_CONF" || { fpm_available=0; return 0; }
    sudo cp "$RUNDIR/nginx-vhost.conf" "$NGINX_CONF" || { fpm_available=0; return 0; }

    # The socket is created by php-fpm at start; clear a stale one first so a
    # previous crashed run cannot leave nginx talking to nothing.
    sudo rm -f "$FPM_SOCKET"
    if ! sudo "$PHP_FPM_BIN" -t >"$RUNDIR/fpm-config-test.log" 2>&1; then
        echo "FPM arm skipped: php-fpm rejected the configuration"
        sed 's/^/    /' "$RUNDIR/fpm-config-test.log" | head -6
        fpm_available=0
        return 0
    fi
    if ! sudo systemctl restart "$FPM_SERVICE" 2>"$RUNDIR/fpm-restart.log"; then
        echo "FPM arm skipped: could not restart $FPM_SERVICE"
        sed 's/^/    /' "$RUNDIR/fpm-restart.log" | head -6
        fpm_available=0
        return 0
    fi
    if ! sudo nginx -t >"$RUNDIR/nginx-config-test.log" 2>&1; then
        echo "FPM arm skipped: nginx rejected the vhost"
        sed 's/^/    /' "$RUNDIR/nginx-config-test.log" | head -6
        fpm_available=0
        return 0
    fi
    sudo systemctl reload nginx 2>/dev/null || sudo nginx -s reload 2>/dev/null

    # Give the pool a moment to bind, then prove it before anything is timed.
    for _ in $(seq 1 40); do [ -S "$FPM_SOCKET" ] && break; sleep 0.25; done
    if [ ! -S "$FPM_SOCKET" ]; then
        echo "FPM arm skipped: $FPM_SOCKET never appeared"
        fpm_available=0
        return 0
    fi

    # Prove the ini the pool actually applied, rather than trusting it. A value
    # that is silently empty (xdebug.mode = off) or a flag php-fpm ignores
    # (opcache.enable_cli) is invisible from the outside and worth 3x, so the
    # effective setting is checked through a request, not through the file.
    probe_ini
}

# Ask the running pool what it thinks its ini is, through nginx.
probe_ini() {
    local probe="$ROOT/public/.bench-ini-probe.php"
    cat > "$probe" <<'PROBE'
<?php
header('Content-Type: text/plain');
foreach (['xdebug.mode', 'opcache.enable_cli', 'opcache.validate_timestamps'] as $k) {
    $v = ini_get($k);
    printf("%s=%s\n", $k, $v === false ? '(unset)' : ($v === '' ? '(empty)' : $v));
}
PROBE
    # A temporary vhost for the probe only, so the measured vhost stays untouched.
    local body
    body="$(curl -sS --max-time 20 "http://127.0.0.1:$ARM_PORT_F/.bench-ini-probe.php" 2>/dev/null)"
    rm -f "$probe"
    echo "  FPM effective ini: $(echo "$body" | tr '\n' ' ')"
    # The `xdebug.mode` case is not hypothetical: a value that is EMPTY rather than
    # absent is what `php_admin_value[xdebug.mode] = off` produces, it leaves the
    # extension loaded, and it costs this arm 3.1x. Printing the effective value turns
    # that from an invisible configuration detail into a line in the log.
    case "$body" in
        # `(unset)` is the good case once the extension is gone: ini_get() returns
        # false when no xdebug registered the setting at all.
        *"xdebug.mode=off"*|*"xdebug.mode=(unset)"*) : ;;
        *"xdebug.mode=(empty)"*)
            echo "  WARNING: xdebug.mode is EMPTY, which leaves xdebug loaded and the arm ~3x low" ;;
        *)
            echo "  WARNING: xdebug.mode is still set, so the FPM arm is inflated."
            echo "           got: $(echo "$body" | tr '\n' ' ')" ;;
    esac
}

teardown_fpm() {
    # Restore xdebug first and unconditionally: leaving the host's php-fpm without it
    # would change other people's measurements.
    restore_fpm_xdebug
    # Remove the pool and vhost first and always: leaving a bad pool behind takes the
    # host's php-fpm down for every other user of the machine.
    sudo rm -f "$FPM_POOL_CONF" "$NGINX_CONF" 2>/dev/null
    [ "$fpm_available" = "1" ] || return 0
    sudo systemctl restart "$FPM_SERVICE" 2>/dev/null
    sudo systemctl reload nginx 2>/dev/null || sudo nginx -s reload 2>/dev/null
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " five ways to serve one page"
echo "=============================================================="
echo "  host:        $(nproc) cores, $(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo) MB"
echo "  php:         $(php -v | head -1)"
echo "  php-cgi:     $PHP_CGI"
echo "  stokehold:   $($BIN version 2>/dev/null | head -1)"
echo "  app:         $ROOT"
echo "  arms:        $ARMS"
echo "  endpoints:   $ENDPOINTS"
echo "  concurrency: $CONC   duration: $DUR   repeats: $REPEAT"
echo "  fair php-cgi ini: $("$PHP_CGI_WRAPPER" -i 2>/dev/null | grep -m1 'opcache.enable_cli' | sed 's/<[^>]*>/ /g' | tr -s ' ')"
echo

# ---------------------------------------------------------------------------
# `opcache.file_update_protection` defaults to 2 seconds: opcache refuses to
# cache a file whose mtime is newer than that. A freshly copied or edited checkout
# therefore misses the opcache on EVERY request *by design*, which is
# indistinguishable from an opcache that does not survive between requests — a
# diagnosis this project has already got wrong once (hazard 28). Nothing here
# edits a file, but a `git checkout` immediately before a run would, so wait it
# out rather than measure a different system from the one described above.
# ---------------------------------------------------------------------------
newest=$(find "$ROOT" -name '*.php' -newermt '-3 seconds' -print -quit 2>/dev/null)
if [ -n "$newest" ]; then
    echo "  a .php file was modified in the last 3s ($newest);"
    echo "  waiting so opcache.file_update_protection cannot skip it by design"
    sleep 3
    echo
fi

: > "$RESULTS"
: > "$LATENCY_RESULTS"
setup_fpm

# ---------------------------------------------------------------------------
# The arms
# ---------------------------------------------------------------------------
for arm in ${ARMS//,/ }; do
    echo "--------------------------------------------------------------"
    case "$arm" in
        P)
            echo "ARM P: stokehold + resident worker (warm, pipe)"
            start_stokehold "$RUNDIR/stoke-pipe.toml" pipe-p
            if wait_port "$ARM_PORT_P" && sanity "$ARM_PORT_P" P; then
                run_client "$ARM_PORT_P" "P stokehold+worker(pipe)" P
                run_latency "$ARM_PORT_P" "P stokehold+worker(pipe)" P
            else
                echo "  ARM P not measured:"; tail -5 "$RUNDIR/server-pipe-p.log" 2>/dev/null
            fi
            stop_arm; sleep 1
            ;;
        T)
            echo "ARM T: stokehold + spawn_cgi (cold, loopback TCP)"
            start_stokehold "$RUNDIR/stoke-cgi-tcp.toml" cgi-t
            if wait_port "$ARM_PORT_T" && sanity "$ARM_PORT_T" T; then
                run_client "$ARM_PORT_T" "T stokehold+spawn_cgi(tcp)" T
                run_latency "$ARM_PORT_T" "T stokehold+spawn_cgi(tcp)" T
            else
                echo "  ARM T not measured:"; tail -5 "$RUNDIR/server-cgi-t.log" 2>/dev/null
            fi
            stop_arm; sleep 1
            ;;
        U)
            echo "ARM U: stokehold + spawn_cgi (cold, unix socket)"
            if [ "$(uname -s)" = "Darwin" ] || [ "$(uname -s)" = "Linux" ]; then
                start_stokehold "$RUNDIR/stoke-cgi-unix.toml" cgi-u
                if wait_port "$ARM_PORT_U" && sanity "$ARM_PORT_U" U; then
                    run_client "$ARM_PORT_U" "U stokehold+spawn_cgi(unix)" U
                run_latency "$ARM_PORT_U" "U stokehold+spawn_cgi(unix)" U
                else
                    echo "  ARM U not measured:"; tail -5 "$RUNDIR/server-cgi-u.log" 2>/dev/null
                fi
            else
                echo "  ARM U skipped: no unix sockets on this platform"
            fi
            stop_arm; sleep 1
            ;;
        R)
            echo "ARM R: RoadRunner + resident worker (warm, pipe)"
            if [ -x "$RR" ]; then
                ( cd "$ROOT" && "$RR" serve -c "$RUNDIR/rr.yaml" >"$RUNDIR/rr.log" 2>&1 ) &
                RR_PID=$!
                if wait_port "$ARM_PORT_R" && sanity "$ARM_PORT_R" R; then
                    run_client "$ARM_PORT_R" "R roadrunner+worker(pipe)" R
                run_latency "$ARM_PORT_R" "R roadrunner+worker(pipe)" R
                else
                    echo "  ARM R not measured:"; tail -8 "$RUNDIR/rr.log" 2>/dev/null
                fi
            else
                echo "  ARM R skipped: no RoadRunner at $RR"
            fi
            stop_arm; sleep 1
            ;;
        F)
            echo "ARM F: nginx + php-fpm (cold, unix socket)"
            if [ "$fpm_available" = "1" ] && wait_port "$ARM_PORT_F" && sanity "$ARM_PORT_F" F; then
                run_client "$ARM_PORT_F" "F nginx+php-fpm(unix)" F
                run_latency "$ARM_PORT_F" "F nginx+php-fpm(unix)" F
            else
                echo "  ARM F not measured"
                tail -5 /var/log/nginx-bench-error.log 2>/dev/null
            fi
            ;;
        *)
            echo "  unknown arm '$arm', skipping"
            ;;
    esac
    echo
done

finish

# ---------------------------------------------------------------------------
# Summary: median of the repeats per cell, so one lucky run cannot become a
# finding. The full per-repeat data is in $RESULTS.
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " summary (median rps of $REPEAT repeat(s))"
echo "=============================================================="
awk -F'\t' '
$6 != "FAIL" {
    key = $1 "\t" $4 "\t" $2;
    n[key]++; rps[key] += $6;
    # p50/p99 are kept per repeat, not averaged: a mean of percentiles is not a
    # percentile, and the spread across repeats is what says whether a cell is
    # stable.
    lat[key] = lat[key] " " $7 "/" $8;
}
END {
    # Sort on a numeric conc inside awk: the key is tab-separated and a shell sort
    # would order by arm name as a string first, putting the rows in an order that
    # does not read as a table.
    for (k in n) {
        split(k, a, "\t");
        printf "%s\t%d\t%s\t%d\t%.0f\t%s\n", a[3], a[2] + 0, a[1], a[2], rps[k]/n[k], lat[k];
    }
}' "$RESULTS" | sort -k1,1 -k2,2n -k3,3 | \
    awk -F'\t' '{ printf "%-10s conc %-3s  %10.0f rps   p50/p99 per repeat:%s\n", $1, $4, $5, $6 }'
echo
echo "raw per-repeat data: $RESULTS"
echo "formatted report:    python3 scripts/report.py $RESULTS"

# A run that leaves processes behind corrupts the next one: hazard 28's 68 orphaned
# php-cgi children each held a port and competed for the cores under test.
#
# The check has to count the right things. `pgrep -c` exits 1 when it matches
# nothing, so a bare `$(pgrep -c x || echo 0)` can print TWO lines ("0" from the
# failed pgrep and "0" from the echo), which makes a string comparison against "0"
# fail for a clean run. And matching on `php-cgi` counts the host's own
# php-fpm-managed children, which belong to php-fpm and not to this run.
count_strays() {
    echo "$(pgrep -c -f 'php-cgi -b' 2>/dev/null || true)" | head -1
}
strays="$(count_strays)"
[ -n "$strays" ] || strays=0
echo "stray php-cgi pools after teardown: $strays"
[ "$strays" = "0" ] || echo "  WARNING: a pool leaked; kill them before the next run"
