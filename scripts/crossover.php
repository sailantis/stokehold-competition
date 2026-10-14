#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * Per-request latency *under concurrency* — the crossover measurement.
 *
 * `latency.php` answers "what does one request cost" with a single connection, and a
 * wrk sweep answers "how many requests per second can twelve slots push". Neither
 * answers the question a deployment actually faces: at what concurrency does a resident
 * worker's advantage stop being visible?
 *
 * The reason it must stop is that php-fpm's per-request framework boot is *work*, and
 * work can be overlapped. At concurrency 1 there is nothing to overlap it with, so the
 * cold arm pays it in full and the warm arm wins by the full ratio. At concurrency 12
 * every slot is busy, one slot's boot coincides with eleven other requests being served,
 * and the aggregate rate stops being sensitive to it — but each individual request still
 * waits for it. That is why throughput and latency disagree, and why both are right.
 *
 * This measures the third thing: the latency of a request while N-1 others are in flight.
 * At N=1 it must reproduce `latency.php`, and that is the check that this file is right
 * rather than merely self-consistent.
 *
 * ## Why N processes instead of curl_multi
 *
 * The first version drove N easy handles from one process with `curl_multi`. It was
 * wrong, and wrong in the way this project keeps being wrong: it reported concurrency 2
 * as exactly 2x the latency of concurrency 1, on three unrelated servers, with throughput
 * flat between them. A real server does not do that. Two causes, both in the client:
 *
 *  1. it read `curl_getinfo(CURLINFO_HTTP_CODE)` *after* `curl_multi_remove_handle`, so
 *     every status came back 0 and every run aborted — or, before that, would have
 *     reported an error page as a fast result;
 *  2. `curl_multi_select($multi, 0.05)` takes **seconds**, so the retry floor was 50 ms.
 *     Measured: 50 ms -> 1,516 rps at concurrency 2 where `wrk` got 3,211. A 0.5 ms
 *     timeout recovered it to 3,306, which matches — and a benchmark that only works
 *     after hand-tuning a magic timeout is one experiment away from lying again.
 *
 * So the generator is N *processes*, each running the same blocking one-request-at-a-time
 * loop `latency.php` uses, which has already been validated against a published
 * dataset. There is no event loop to tune and no polling to get wrong: a process is
 * blocked in `curl_exec` or it is not, and the kernel schedules it. The cost is N PHP
 * startups per run, which affects `rps` slightly and the latency samples not at all.
 *
 * ## What it does not do
 *
 * It does not model think time: N closed-loop clients with zero think time saturate as
 * hard as they can, which is the worst case for the cold arm. It does not pin clients to
 * cores, so a client can share one with a server slot. Both are stated rather than
 * hidden, and both make the *warm* arm look relatively better than a real traffic mix
 * would.
 *
 * Usage:
 *   php scripts/crossover.php <base-url> <uri> <conc> <iters-per-client> <runs> <label> [marker]
 *   php scripts/crossover.php http://127.0.0.1:18400 /items 8 200 3 "P worker" "Benchmark Item"
 *
 * Output: one line per run, tab-separated.
 *   label  conc  run  median_ms  mean_ms  min_ms  p95_ms  p99_ms  rps  status
 */

/**
 * Number of untimed requests before timing, per client.
 *
 * Enough that a lazily-compiled route table and a cold opcache are behind us. The child
 * verifies the warm-up response, so a client that never reached the application fails the
 * run rather than contributing fast samples from an error page.
 */
const WARMUP = 50;

const CURL_OPTS = [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
    CURLOPT_TIMEOUT => 30,
    CURLOPT_CONNECTTIMEOUT => 10,
];

// Child mode: one connection, `iters` timed requests, raw samples to a file.
//
// This must come after the constants above — a top-level `const` is not hoisted the way a
// function is, so `CURL_OPTS` really does not exist yet if this runs from the top of the
// file — and it must come before the parent's argument parsing, because in child mode
// `$argv[4]` is a samples *path* and parsing it as an iteration count yields 0, which the
// parent's validation then rejects with its own usage message.
if (($argv[1] ?? '') === '--child') {
    exit(childMain($argv));
}

$baseUrl = rtrim((string) ($argv[1] ?? ''), '/');
$uri = (string) ($argv[2] ?? '/items');
$concurrency = (int) ($argv[3] ?? 1);
$iters = (int) ($argv[4] ?? 200);
$runs = (int) ($argv[5] ?? 3);
$label = (string) ($argv[6] ?? $baseUrl);
$marker = (string) ($argv[7] ?? 'Benchmark Item');

if ($baseUrl === '' || $concurrency < 1 || $iters < 1 || $runs < 1) {
    fwrite(STDERR, "usage: crossover.php <base-url> <uri> <conc> <iters> <runs> [label] [marker]\n");
    exit(2);
}

/**
 * Child process: sequential requests on one reused connection.
 *
 * Deliberately the same shape as `latency.php`, including the verified warm-up and the
 * `hrtime()` bracketing of a single `curl_exec`. Writes one sample per line in ms to
 * `$argv[5]`, or an `ERROR` line and a non-zero exit.
 */
function childMain(array $argv): int
{
    $baseUrl = rtrim((string) ($argv[2] ?? ''), '/');
    $uri = (string) ($argv[3] ?? '/items');
    $iters = (int) ($argv[4] ?? 200);
    $samplesPath = (string) ($argv[5] ?? '');
    $marker = (string) ($argv[6] ?? 'Benchmark Item');

    if ($baseUrl === '' || $samplesPath === '') {
        fwrite(STDERR, "child: missing arguments\n");

        return 2;
    }

    $ch = curl_init();
    curl_setopt_array($ch, CURL_OPTS + [CURLOPT_URL => $baseUrl . $uri]);

    $handle = fopen($samplesPath, 'wb');
    if ($handle === false) {
        fwrite(STDERR, "child: cannot write $samplesPath\n");

        return 2;
    }

    $fetch = static function () use ($ch): string {
        $body = curl_exec($ch);
        if ($body === false) {
            throw new RuntimeException('request failed: ' . curl_error($ch));
        }

        return (string) $body;
    };

    $lines = 0;
    try {
        $body = '';
        for ($i = 0; $i < WARMUP; $i++) {
            $body = $fetch();
        }

        // A 200 is not evidence. A broken arm served from cache, or an error page, is
        // faster than the real thing and would look like the winner.
        $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        if ($status !== 200 || !str_contains($body, $marker)) {
            throw new RuntimeException(sprintf(
                'warm-up returned HTTP %d, %d bytes, marker %s',
                $status,
                strlen($body),
                str_contains($body, $marker) ? 'present' : 'MISSING'
            ));
        }

        for ($i = 0; $i < $iters; $i++) {
            $t0 = hrtime(true);
            $fetch();
            $t1 = hrtime(true);
            fwrite($handle, sprintf("%.4f\n", ($t1 - $t0) / 1e6));
            $lines++;
        }
    } catch (RuntimeException $e) {
        fclose($handle);
        // The partial file is left behind but the parent checks the exit code, so a
        // short file cannot be mistaken for a cheap run.
        fwrite(STDERR, "child: {$e->getMessage()}\n");

        return 1;
    }

    fclose($handle);

    return $lines === $iters ? 0 : 1;
}

/**
 * Run `$concurrency` children at once and return their merged samples in ms.
 *
 * @return array{samples: array<int, float>, wall: float}
 */
function runConcurrent(string $self, string $baseUrl, string $uri, int $concurrency, int $iters, string $marker, string $scratch): array
{
    $procs = [];
    $files = [];
    $pipes = [];

    for ($i = 0; $i < $concurrency; $i++) {
        $file = sprintf('%s/samples-%d.txt', $scratch, $i);
        $files[$i] = $file;
        $cmd = [PHP_BINARY, $self, '--child', $baseUrl, $uri, (string) $iters, $file, $marker];
        $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
        $proc = proc_open($cmd, $descriptors, $pipes[$i]);
        if (!is_resource($proc)) {
            throw new RuntimeException("could not start client $i");
        }
        $procs[$i] = $proc;
    }

    // The clock starts once every client is running and stops when the last one is done,
    // so `rps` is the aggregate rate of the whole group. Each client's startup is inside
    // the wall time, which at these iteration counts is a few percent of it and the same
    // for every arm.
    $wallStart = hrtime(true);

    $failures = [];
    foreach ($procs as $i => $proc) {
        $out = stream_get_contents($pipes[$i][1]);
        $err = stream_get_contents($pipes[$i][2]);
        fclose($pipes[$i][1]);
        fclose($pipes[$i][2]);
        $code = proc_close($proc);
        if ($code !== 0) {
            $failures[] = "client $i exited $code: " . trim($err ?: $out);
        }
    }

    $wall = (hrtime(true) - $wallStart) / 1e9;

    if ($failures !== []) {
        throw new RuntimeException(implode('; ', array_slice($failures, 0, 3)));
    }

    $samples = [];
    foreach ($files as $file) {
        $contents = file_get_contents($file);
        if ($contents === false) {
            throw new RuntimeException("missing samples from $file");
        }
        foreach (explode("\n", trim($contents)) as $line) {
            if ($line !== '') {
                $samples[] = (float) $line;
            }
        }
    }

    return ['samples' => $samples, 'wall' => $wall];
}

function percentile(array $sorted, float $p): float
{
    $n = count($sorted);

    return $sorted[min($n - 1, (int) floor($n * $p))];
}

$scratch = sys_get_temp_dir() . '/volucer-crossover-' . getmypid();
if (!is_dir($scratch) && !mkdir($scratch, 0o700, true)) {
    fwrite(STDERR, "cannot create $scratch\n");
    exit(2);
}

$exit = 0;
for ($run = 1; $run <= $runs; $run++) {
    try {
        $r = runConcurrent(__FILE__, $baseUrl, $uri, $concurrency, $iters, $marker, $scratch);
    } catch (RuntimeException $e) {
        fwrite(STDERR, "ABORT $label conc $concurrency: {$e->getMessage()}\n");
        $exit = 1;
        break;
    }

    $samples = $r['samples'];
    sort($samples);
    $n = count($samples);
    $median = $n % 2 ? $samples[intdiv($n, 2)] : ($samples[$n / 2 - 1] + $samples[$n / 2]) / 2;

    printf(
        "%s\t%d\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.4f\t%.1f\t%s\n",
        $label,
        $concurrency,
        $run,
        $median,
        array_sum($samples) / $n,
        $samples[0],
        percentile($samples, 0.95),
        percentile($samples, 0.99),
        $n / $r['wall'],
        'ok'
    );

    foreach (glob("$scratch/samples-*.txt") ?: [] as $file) {
        unlink($file);
    }
}

foreach (glob("$scratch/*") ?: [] as $file) {
    unlink($file);
}
rmdir($scratch);

exit($exit);
