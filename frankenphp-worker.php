<?php

declare(strict_types=1);

/**
 * The FrankenPHP arm's entry point: the third resident worker.
 *
 * `worker.php` (volucer) and `roadrunner-worker.php` exist to keep the warm half
 * of the comparison from resting on one implementation. This one is here for a
 * different reason: FrankenPHP is the other server that embeds a PHP runtime
 * *inside* its own process, which is the one architectural choice volucer
 * deliberately rejects (no embedding, no FFI — see the plan's constraints). If the
 * question is ever "what does embedding buy you", this arm is the number that
 * answers it.
 *
 * It drives the same `BenchApp` as every other arm, so the application is held
 * equal and only the server differs. Two things about the loop are not free
 * choices:
 *
 *   * `frankenphp_handle_request()` is the whole worker protocol. It hands the
 *     engine the current request, populates the superglobals, and returns false
 *     when the worker should stop. Nothing is read from stdin and nothing is
 *     framed here, because the transport is a function call rather than a pipe.
 *
 *   * `gc_collect_cycles()` after every request is what FrankenPHP's own worker
 *     example does, and it is not optional in worker mode: without it the cycle
 *     collector runs in the middle of a page generation instead of between pages,
 *     which shows up as a latency tail rather than as memory.
 *
 * Recycling is deliberately NOT implemented here. `max_requests` is the
 * Caddyfile's business and is set to 0 there, matching `max_requests = 0` on the
 * volucer and RoadRunner arms and `pm.max_requests = 0` on the FPM pool.
 */

require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/BenchApp.php';

/*
 * Report the ini this thread actually ended up with, once, per worker.
 *
 * This is not decoration. FrankenPHP bundles its own PHP, and on this host the
 * release binary loads NO php.ini at all (`php_ini_loaded_file()` is empty), so it
 * runs with PHP's compiled-in defaults: memory_limit 128M and
 * opcache.validate_timestamps ON. Those are exactly the settings hazard 28 is
 * about — a difference of ini that reads as a difference of server. The harness
 * points the arm at a php.ini and the Caddyfile sets `php_ini`, and a setting that
 * looks right in either and is not applied is invisible from the outside — so it is
 * read back from inside the thread that serves the requests. Twelve lines, one per
 * worker.
 *
 * `error_log()` and not `fwrite(STDERR, ...)`: in this SAPI there IS no STDERR.
 * A worker's output is the HTTP response and nothing else, so the constant is
 * undefined and writing to it is a fatal error that happens BEFORE the request
 * loop — which is what "has not reached frankenphp_handle_request()" means when the
 * arm refuses to start. `error_log()` goes to the error log Caddy is already writing
 * to, and that log is captured per arm by the harness.
 */
error_log(sprintf(
    '[frankenphp-worker] pid %d  php %s  ini %s  memory_limit=%s  opcache=%s  validate_timestamps=%s',
    getmypid(),
    PHP_VERSION,
    php_ini_loaded_file() ?: '(none)',
    ini_get('memory_limit'),
    var_export((bool) ini_get('opcache.enable'), true),
    var_export((bool) ini_get('opcache.validate_timestamps'), true),
));

$dbPath = __DIR__ . '/data/bench.sqlite';
if (!file_exists($dbPath)) {
    error_log('Database not found. Run: php seed.php');
    exit(1);
}

$app = new BenchApp($dbPath);
// The boot the cold arms pay per request, paid once here.
$app->bootstrap();

// Counts requests this loop is asked to serve. See the handler for why it exists.
$served = 0;

$handler = static function () use ($app, &$served): void {
    /*
     * Report, once per worker thread, the first request this loop is actually asked
     * to serve.
     *
     * This is a self-check with teeth, and it exists because the failure it catches
     * is silent. FrankenPHP's `php_server` runs a `worker` only where `match` says
     * so, and its default is "requests for a .php file" — every other path is handed
     * to the ordinary per-request PHP handler instead. That configuration answers
     * every request with a correct 200 and the correct body; it is simply a cold
     * server wearing a warm server's name. Measured on this host, `GET /items`: the
     * worker path gives 15,856 rps, the same binary without `match` gives 662.
     *
     * Nothing in an HTTP response distinguishes them, and timing does not either —
     * an unloaded request takes ~0.8 ms warm and ~2.0 ms cold here, which is far too
     * close to separate on a shared host. But if the worker loop is never entered,
     * this line is never written, and the arm's own log can be checked for it. The
     * harness does exactly that.
     */
    if ($served++ === 0) {
        error_log(sprintf('[frankenphp-worker] pid %d served its first request', getmypid()));
    }

    try {
        // The same two superglobals `public/index.php` reads, so the router and the
        // paginator see the same input on every arm. FrankenPHP repopulates them
        // per request; it does not re-run this file.
        $result = $app->dispatch(
            $_SERVER['REQUEST_METHOD'] ?? 'GET',
            $_SERVER['REQUEST_URI'] ?? '/',
        );
        // Drop this request's scope, or the next one inherits it.
        $app->cleanup();

        http_response_code($result->status);
        header('Content-Type: text/html; charset=utf-8');
        echo $result->body;
    } catch (\Throwable $e) {
        // Report rather than exit: a worker that dies takes the comparison with it,
        // and a 500 row is a measurement while a dead worker is not.
        http_response_code(500);
        header('Content-Type: text/plain');
        echo 'ERROR: ' . $e->getMessage();
    }
};

while (\frankenphp_handle_request($handler)) {
    gc_collect_cycles();
}
