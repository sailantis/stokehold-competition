<?php

declare(strict_types=1);

/**
 * The COLD arm's entry point: what nginx + php-fpm and volucer + spawn_cgi run.
 *
 * This file exists separately from `worker.php` on purpose. A cold arm must pay
 * the framework's boot *inside the timed request*, and the only honest way to
 * show that is for the entry script itself to boot — which is exactly what
 * php-fpm does with a front controller, and what `spawn_cgi` does with a full CGI
 * SAPI reset. Sharing the worker's loop here would quietly make the cold arms
 * warm and erase the effect being measured.
 */

// `public/` is not the repo root: the data directory, the app and the vendor
// tree all live one level up.
$root = dirname(__DIR__);
$dbPath = $root . '/data/bench.sqlite';

if (!file_exists($dbPath)) {
    http_response_code(500);
    echo 'Database not found. Run: php seed.php';
    exit;
}

// The application's own namespace comes from composer's PSR-4 map
// (`App\Azera\` -> `apps/azera/`), so both this file and the worker resolve
// `App\Azera\Bootstrap` the same way. Keeping the mapping in one place is what
// stops the warm and cold arms from disagreeing about which code they run.
require $root . '/vendor/autoload.php';
require $root . '/BenchApp.php';

$app = new BenchApp($dbPath);
$app->bootstrap();

$result = $app->dispatch(
    $_SERVER['REQUEST_METHOD'] ?? 'GET',
    $_SERVER['REQUEST_URI'] ?? '/',
);
$app->cleanup();

http_response_code($result->status);
header('Content-Type: text/html; charset=utf-8');
echo $result->body;
