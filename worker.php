<?php

declare(strict_types=1);

/**
 * The WARM arm's entry point: what stokehold's `worker` backend runs.
 *
 * The counterpart of `public/index.php`, and the contrast is the experiment. The
 * same `BenchApp` and the same page, but `bootstrap()` runs ONCE here, before the
 * loop, and every request reuses the container it built. That single line moving
 * out of the request is the whole difference between the warm and cold arms.
 *
 * `run()` owns the framing: `Request` already carries the method and URI, and the
 * SDK rebinds PHP's own output so an `echo` inside application code cannot
 * corrupt the protocol channel (see the SDK's README).
 */

require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/BenchApp.php';

$dbPath = __DIR__ . '/data/bench.sqlite';
if (!file_exists($dbPath)) {
    fwrite(STDERR, "Database not found. Run: php seed.php\n");
    exit(1);
}

$app = new BenchApp($dbPath);
// The boot the cold arms pay per request.
$app->bootstrap();

/*
 * stokehold can reach a worker two ways, and this file drives both so the warm arm
 * can be measured on either.
 *
 * The default is the worker's own stdin/stdout, which is what this file has always
 * used and what the server assumes when `STOKEHOLD_WORKER_SOCKET` is absent. The
 * alternative is a loopback socket, and it exists for one measured reason: on Windows,
 * PHP's stream layer takes ~8 ms median to return from a blocking read on a *pipe* while
 * the same read on a *socket* returns in ~0.09 ms. A Rust process reading the identical
 * pipe returns in 0.010 ms, so the cost is PHP-on-Windows rather than the pipe itself.
 *
 * `Worker::connect()` is the whole decision — the protocol does not know which transport
 * it is on, so nothing else in this file changes.
 */
$worker = Stokehold\Worker::connect();

$worker->run(static function (Stokehold\Request $request) use ($app): Stokehold\Response {
    $result = $app->dispatch($request->method, $request->uri);
    // Drop this request's scope, or the next one inherits it.
    $app->cleanup();

    return new Stokehold\Response(
        $result->status,
        [['Content-Type', 'text/html; charset=utf-8']],
        $result->body,
    );
});
