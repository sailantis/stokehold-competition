#!/bin/bash
# Why does the embedded runtime stop scaling?
#
# The interleaved run leaves a specific shape: FrankenPHP is the fastest arm at
# concurrency 1 and then flattens, while volucer roughly doubles from 8 to 32. Two
# very different explanations, and they lead to opposite conclusions:
#
#   (a) CPU-BOUND. The embedded runtime burns all twelve cores and 16k rps is simply
#       what its interpreter costs per request. Then the ceiling is a property of
#       embedding, the arm is measuring that honestly, and there is nothing to fix.
#
#   (b) BLOCKING-BOUND. The server is capped while cores sit idle, the way a single
#       `read()` on a blocking stream caps a worker regardless of how many threads are
#       waiting. Then the cap is a defect, and 16k is not what the model is worth.
#
# The two are separated by accounting rather than by argument: sample CPU time consumed
# by the server's whole process tree across a saturated run, and compare it with core
# count times wall time. A CPU-bound server uses close to all of it.
#
# Reading CPU out of /proc/<pid>/stat rather than `top` is deliberate — `top`'s
# instantaneous percentages bounce around by tens of points and a snapshot during a
# 10-second run is a sample of nothing. utime+stime deltas over the whole window are
# the integral.
#
# The client's own CPU is measured too. `wrk` at concurrency 32 on a 12-core box is
# itself a real process; if it is eating a core and a half, that belongs in the
# accounting and not in the conclusion.
#
# Usage: bash diag-franken-cpu.sh
set -uo pipefail

ROOT="${ROOT:-$HOME/workspace/volucer-competition}"
RUNDIR="${RUNDIR:-$HOME/volucer-bench-run-ab}"
FP="${FP:-$HOME/bin/frankenphp}"
RR="${RR:-$HOME/bin/rr}"
BIN="${BIN:-$HOME/volucer-bench/target/release/volucer}"
WORKERS="${WORKERS:-12}"
CONC="${CONC:-16}"
# Seconds, as a plain integer: this value is used in arithmetic and in `sleep`, and a
# `12s` here is not accepted by `$(( ))`. The first version of this script had the
# suffix baked in and measured nothing at all.
DUR="${DUR:-12}"
CORES="$(nproc)"

for f in "$RUNDIR/franken.caddyfile" "$RUNDIR/rr.yaml" "$RUNDIR/new-req.toml"; do
    [ -f "$f" ] || { echo "FATAL: $f missing - run ab-perf.sh first so the configs exist"; exit 1; }
done

# --- the process tree of each server, matched the way ab-perf.sh matches it -------
server_pids() {
    case "$1" in
        franken) ps -eww -o pid=,args= | awk -v d="$RUNDIR" '$0 ~ (d "/.*[.]caddyfile") {print $1}' ;;
        rr) ps -eww -o pid=,args= | awk -v d="$RUNDIR" '$0 ~ (d "/rr[.]yaml") {print $1}'
            ps -eww -o pid=,args= | awk -v r="$ROOT" '$0 ~ (r "/roadrunner-worker[.]php") {print $1}' ;;
        new-req) ps -eww -o pid=,args= | awk -v d="$RUNDIR" '$0 ~ (d "/new-req[.]toml") {print $1}'
            ps -eww -o pid=,args= | awk -v r="$ROOT" '$0 ~ (r "/worker[.]php") {print $1}' ;;
    esac
}

# utime + stime in clock ticks (USER_HZ, 100 here). Fields 14 and 15 of
# /proc/<pid>/stat, after the comm field that can contain spaces and parentheses.
ticks_of() {
    local pid="$1"
    awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0
}

sum_ticks() {
    local kind="$1" total=0 pid t
    for pid in $(server_pids "$kind"); do
        t="$(ticks_of "$pid")"
        total=$((total + t))
    done
    echo "$total"
}

wrk_pids() { ps -eww -o pid=,args= | awk '$0 ~ /[w]rk -t/ {print $1}'; }
sum_wrk_ticks() {
    local total=0 pid t
    for pid in $(wrk_pids); do
        t="$(ticks_of "$pid")"
        total=$((total + t))
    done
    echo "$total"
}

PID=""
FP_PID=""
RR_PID=""
stop() {
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    [ -n "$FP_PID" ] && kill "$FP_PID" 2>/dev/null
    [ -n "$RR_PID" ] && kill "$RR_PID" 2>/dev/null
    pkill -f "$RUNDIR/.*[.]caddyfile" 2>/dev/null
    pkill -f "$RUNDIR/rr.yaml" 2>/dev/null
    pkill -f "$RUNDIR/new-req.toml" 2>/dev/null
    sleep 1
}
trap stop EXIT
# And once up front, before anything else: a leftover from an interrupted run is the
# failure mode this script is most exposed to, because every port it uses is one a
# previous invocation may still be holding.
stop

wait_port() {
    local port="$1" i
    for i in $(seq 1 80); do
        curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/items" 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}

# A port already in use poisons the whole measurement, and silently: `wait_port`
# below succeeds immediately, but it is answering from the OLD server, so the number
# that comes out belongs to a process this script did not start and cannot vouch for.
# It happened on the first version of this script — a FrankenPHP left behind by an
# earlier failed run held 19900, the freshly started one could not bind and exited,
# and the table reported 4,478 rps for an arm that measures 15,300. The server under
# test must be proven to be the one this script started.
port_is_free() {
    ! curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/" 2>/dev/null
}

printf "%-9s %5s %7s %12s %12s %10s %10s %s\n" \
    variant conc "pids" "server CPU s" "client CPU s" "server %" "cores used" "rps"
echo "-------------------------------------------------------------------------------------------------"
# `wrk` has to be sampled WHILE it runs: it exits at the end of the window, and a
# client that is no longer alive contributes nothing to a post-hoc reading. That
# mistake produced a table of zeroes on the first attempt. So the client is started
# in the background and the CPU window is a slice out of the middle of its run, where
# both processes are at steady state.
measure() {
    local kind="$1" port="$2" cfg="$3"
    if ! port_is_free "$port"; then
        echo "$kind: FAILED - port $port is already in use, so any number here would"
        echo "        be another process's. Refusing to measure it."
        stop
        return 1
    fi
    case "$kind" in
        franken) "$FP" run --config "$cfg" --adapter caddyfile >"$RUNDIR/cpu-$kind.log" 2>&1 & FP_PID=$! ;;
        rr) ( cd "$ROOT" && exec "$RR" serve -c "$cfg" ) >"$RUNDIR/cpu-$kind.log" 2>&1 & RR_PID=$! ;;
        *) "$BIN" serve -c "$cfg" >"$RUNDIR/cpu-$kind.log" 2>&1 & PID=$! ;;
    esac
    if ! wait_port "$port"; then
        echo "$kind: did not come up"; stop; return 1
    fi

    # Warm up so the sample window is steady state and not pool start-up.
    wrk -t"$WORKERS" -c"$WORKERS" -d3s "http://127.0.0.1:$port/items" >/dev/null 2>&1
    sleep 1

    local npid s0 c0 s1 c1 out rps
    npid="$(server_pids "$kind" | wc -w | tr -d ' ')"
    out="$(mktemp)"
    wrk -t"$CONC" -c"$CONC" -d"$((DUR + 6))s" "http://127.0.0.1:$port/items" >"$out" 2>/dev/null &
    local wpid=$!
    sleep 3
    s0="$(sum_ticks "$kind")"
    c0="$(sum_wrk_ticks)"
    sleep "$DUR"
    s1="$(sum_ticks "$kind")"
    c1="$(sum_wrk_ticks)"
    wait "$wpid" 2>/dev/null || true
    rps="$(awk '/^Requests\/sec:/{print $2; exit}' "$out")"
    rm -f "$out"

    awk -v k="$kind" -v c="$CONC" -v np="$npid" -v s="$((s1 - s0))" -v cl="$((c1 - c0))" \
        -v dur="$DUR" -v cores="$CORES" -v rps="${rps:-0}" 'BEGIN {
        ss = s / 100; cs = cl / 100;
        printf "%-9s %5s %7s %12.2f %12.2f %9.1f%% %10.2f %s\n",
            k, c, np, ss, cs, (ss / dur) / cores * 100, ss / dur, rps
    }'
    stop
}

measure franken 19900 "$RUNDIR/franken.caddyfile"
measure rr      19901 "$RUNDIR/rr.yaml"
measure new-req 19902 "$RUNDIR/new-req.toml"
echo
echo "  server %   = share of all $CORES cores consumed by the server's process tree"
echo "  cores used = server CPU-seconds per wall-second (a CPU-bound server reaches $CORES)"
echo
echo "=== strays ==="
ps -eww -o args | grep -E '[f]rankenphp run|[r]r serve|volucer serve' | head
