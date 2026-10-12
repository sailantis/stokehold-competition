#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * Sequential per-request latency — the methodology `azera-competition` published.
 *
 * This exists because throughput and latency answer different questions and the two
 * disagreed here. That harness measured `hrtime()` around one `curl_exec` at a time
 * with a reused connection, and reported ~3.1x between a resident worker and
 * nginx+php-fpm; a wrk throughput sweep with 12 slots reports about 1.0x on the same
 * route. Both can be right about different things, so the published primitive is
 * reproduced here rather than argued about.
 *
 * What it does NOT do that a load generator does:
 *   - no concurrency. Requests are strictly sequential, so this measures the cost of
 *     one request, not the behaviour of a saturated pool. A 12-slot server at
 *     concurrency 1 has 11 idle slots, which is a different system from a busy one.
 *   - one connection, kept alive. The connection is established once and reused for
 *     every timed request, so the server's per-request path is what is measured and
 *     the TCP handshake is not. `connect_ms` is reported so a run where reuse failed
 *     (and every request paid a connect) is visible rather than silently averaged in.
 *
 * The warm-up is untimed and its response is VERIFIED. A server that boots lazily, or
 * one that was never listening, would otherwise contribute its first-request cost or
 * a stream of 502s to the numbers — and a 502 is served far faster than a rendered
 * page, so a broken arm would look like the fastest one.
 *
 * Usage:
 *   php scripts/latency.php <base-url> <uri> [iterations] [runs] [label] [marker]
 *   php scripts/latency.php http://127.0.0.1:18400 /items 1000 10 "P worker" "Benchmark Item"
 *
 * Output: one line per run, tab-separated, for a shell aggregator.
 *   label  run  median_ms  mean_ms  min_ms  p95_ms  connect_ms  status
 */

$baseUrl = rtrim((string) ($argv[1] ?? ''), '/');
$uri = (string) ($argv[2] ?? '/items');
$iterations = (int) ($argv[3] ?? 1000);
$runs = (int) ($argv[4] ?? 10);
$label = (string) ($argv[5] ?? $baseUrl);
// The marker is per endpoint and must be supplied: `/` renders no rows, so a
// hard-coded "Benchmark Item" would abort every `/` measurement — which is a safe
// failure (no number) but a wasted run.
$marker = (string) ($argv[6] ?? 'Benchmark Item');

if ($baseUrl === '') {
    fwrite(STDERR, "usage: latency.php <base-url> <uri> [iterations] [runs] [label] [marker]\n");
    exit(2);
}

/**
 * How many warm-up requests before timing starts.
 *
 * Enough that a lazily-compiled route table and a cold opcache are both behind us;
 * the first request to a fresh server can be an order of magnitude slower and it is
 * not the thing being measured.
 */
const WARMUP = 50;

/** A body marker that only the rendered page has. A 200 is not evidence. */
const MARKER_DEFAULT = 'Benchmark Item';

function stats(array $samples): array
{
    sort($samples);
    $n = count($samples);
    $sum = array_sum($samples);

    return [
        'min' => $samples[0],
        'mean' => $sum / $n,
        'median' => $n % 2 ? $samples[intdiv($n, 2)] : ($samples[$n / 2 - 1] + $samples[$n / 2]) / 2,
        'p95' => $samples[min($n - 1, (int) floor($n * 0.95))],
    ];
}

$ch = curl_init();
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
    CURLOPT_TIMEOUT => 30,
    CURLOPT_CONNECTTIMEOUT => 10,
]);

$fetch = static function () use ($ch, $baseUrl, $uri): string {
    curl_setopt($ch, CURLOPT_URL, $baseUrl . $uri);
    $body = curl_exec($ch);
    if ($body === false) {
        throw new RuntimeException('request failed: ' . curl_error($ch));
    }

    return (string) $body;
};

// --- warm-up, untimed, verified ---------------------------------------------
try {
    $body = '';
    for ($i = 0; $i < WARMUP; $i++) {
        $body = $fetch();
    }
} catch (RuntimeException $e) {
    fwrite(STDERR, "ABORT $label: warm-up failed: {$e->getMessage()}\n");
    exit(1);
}

$status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
if ($status !== 200 || !str_contains($body, $marker)) {
    fwrite(STDERR, sprintf(
        "ABORT %s: warm-up returned HTTP %d, %d bytes, marker %s\n  body head: %s\n",
        $label,
        $status,
        strlen($body),
        str_contains($body, $marker) ? 'present' : 'MISSING',
        substr($body, 0, 200)
    ));
    exit(1);
}

// --- timed runs -------------------------------------------------------------
for ($run = 1; $run <= $runs; $run++) {
    $samples = [];
    $connectTotal = 0.0;

    for ($i = 0; $i < $iterations; $i++) {
        try {
            $t0 = hrtime(true);
            $fetch();
            $t1 = hrtime(true);
        } catch (RuntimeException $e) {
            fwrite(STDERR, "ABORT $label: {$e->getMessage()}\n");
            exit(1);
        }

        $samples[] = ($t1 - $t0) / 1e6;
        $connectTotal += (float) curl_getinfo($ch, CURLINFO_CONNECT_TIME) * 1000.0;
    }

    $s = stats($samples);
    printf(
        "%s\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.4f\t%d\n",
        $label,
        $run,
        $s['median'],
        $s['mean'],
        $s['min'],
        $s['p95'],
        $connectTotal / $iterations,
        $status
    );
}
