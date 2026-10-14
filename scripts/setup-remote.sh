#!/bin/bash
# Provision a fresh Linux host for the five-arm benchmark.
#
# Only the things that are not already part of a PHP deployment: `wrk` for the
# load, nginx + php-fpm for the reference cold arm, and the php-cgi ini the cold
# volucer arms need. Idempotent — safe to re-run.
#
# Usage:
#   bash scripts/setup-remote.sh              # everything
#   SKIP_FPM=1 bash scripts/setup-remote.sh   # wrk + php-cgi only
set -uo pipefail

SKIP_FPM="${SKIP_FPM:-0}"
SUDO=""
command -v sudo >/dev/null 2>&1 && SUDO="sudo"

need() { command -v "$1" >/dev/null 2>&1; }

echo "=== host ==="
echo "  $(nproc) cores, $(free -m | awk '/Mem:/ {print $2}') MB"
. /etc/os-release 2>/dev/null && echo "  ${PRETTY_NAME:-unknown}"
echo

install_pkgs() {
    if need apt-get; then
        $SUDO apt-get update -qq
        $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
    elif need dnf; then
        $SUDO dnf install -y -q "$@"
    elif need apk; then
        $SUDO apk add --no-cache "$@"
    else
        echo "  no known package manager; install by hand: $*"
        return 1
    fi
}

# --- wrk --------------------------------------------------------------------
if need wrk; then
    echo "wrk: already installed ($(wrk --version 2>&1 | head -1))"
else
    echo "wrk: installing"
    install_pkgs wrk || echo "  wrk is not packaged here; build it from https://github.com/wg/wrk"
fi

# --- php-cgi ----------------------------------------------------------------
#
# The cold volucer arms drive php-cgi directly. Note it is NOT installed by the
# php-fpm package on every distribution.
if need php-cgi; then
    echo "php-cgi: already installed ($(php-cgi -v 2>&1 | head -1))"
else
    echo "php-cgi: installing"
    install_pkgs php8.3-cgi || install_pkgs php-cgi
fi

if [ "$SKIP_FPM" = "1" ]; then
    echo
    echo "SKIP_FPM=1: not touching nginx or php-fpm."
    exit 0
fi

# --- nginx + php-fpm --------------------------------------------------------
#
# The reference arm: the deployment every PHP shop already runs.
if need nginx; then
    echo "nginx: already installed"
else
    echo "nginx: installing"
    install_pkgs nginx
fi

if need php-fpm8.3 || need php-fpm; then
    echo "php-fpm: already installed"
else
    echo "php-fpm: installing"
    install_pkgs php8.3-fpm || install_pkgs php-fpm
fi

# php-fpm's pool directory must exist and be readable by the service, or
# bench.sh's `sudo cp` writes a file nobody loads and the arm silently never
# starts.
FPM_POOL_DIR=/etc/php/8.3/fpm/pool.d
if [ -d "$FPM_POOL_DIR" ]; then
    echo "php-fpm pool dir: $FPM_POOL_DIR"
else
    echo "php-fpm pool dir: not at $FPM_POOL_DIR — check where your php-fpm looks"
fi

echo
echo "=== verify ==="
for b in wrk php php-cgi nginx; do
    if need "$b"; then echo "  $b: $(command -v "$b")"; else echo "  $b: MISSING"; fi
done
for s in php8.3-fpm php-fpm; do
    need "$s" && echo "  $s: $(command -v "$s")"
done
echo
echo "Passwordless sudo is needed for the FPM arm (it writes one pool file and one"
echo "vhost, both named bench-volucer, and removes them). Test it with: sudo -n true"
