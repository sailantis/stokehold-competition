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

$worker = Stokehold\Worker::create();

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
