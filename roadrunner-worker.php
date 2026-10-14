<?php

declare(strict_types=1);

/**
 * The RoadRunner worker — the second warm arm.
 *
 * It exists to make the warm half of the comparison independent. Two servers
 * implementing the same model should agree; if they do not, the difference is a
 * property of one server rather than of the model, and no conclusion about
 * "resident workers versus per-request boot" can be drawn from the pair.
 *
 * It drives the same `BenchApp` as `worker.php`, so the application is held equal
 * and only the server differs. The loop is longer than volucer's because
 * RoadRunner's SDK hands over a PSR-7 request that has to be turned back into a
 * method and URI, and because it requires an explicit `respond()`.
 */

require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/BenchApp.php';

use Spiral\RoadRunner\Http\PSR7Worker;
use Spiral\RoadRunner\Worker;

$dbPath = __DIR__ . '/data/bench.sqlite';
if (!file_exists($dbPath)) {
    fwrite(STDERR, "Database not found. Run: php seed.php\n");
    exit(1);
}

$app = new BenchApp($dbPath);
$app->bootstrap();

$factory = new Nyholm\Psr7\Factory\Psr17Factory();
$psr7 = new PSR7Worker(
    Worker::create(),
    $factory,   // ServerRequestFactoryInterface
    $factory,   // StreamFactoryInterface
    $factory,   // UploadedFileFactoryInterface
);

while ($request = $psr7->waitRequest()) {
    try {
        // RoadRunner gives a PSR-7 URI object, so path and query have to be put
        // back together — the application reads one URI string on every arm.
        $uri = $request->getUri();
        $target = $uri->getPath();
        if ($uri->getQuery() !== '') {
            $target .= '?' . $uri->getQuery();
        }

        $result = $app->dispatch($request->getMethod(), $target);
        $app->cleanup();

        $response = new Nyholm\Psr7\Response(
            $result->status,
            ['Content-Type' => 'text/html; charset=utf-8'],
            $result->body,
        );
    } catch (Throwable $e) {
        // Report rather than exit: a worker that dies takes the comparison with
        // it, and a 500 row is a measurement while a dead worker is not.
        $response = new Nyholm\Psr7\Response(
            500,
            ['Content-Type' => 'text/plain'],
            'ERROR: ' . $e->getMessage(),
        );
    }

    $psr7->respond($response);
}
