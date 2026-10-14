# FrankenPHP, measured the same way

The sixth arm. It is here to answer a question about *architecture* rather than about
tuning, and it is the only arm in this repository that can.

**FrankenPHP embeds the PHP interpreter inside its own process.** A Caddy server with a
ZTS PHP built into the binary, one process, twelve worker threads. Every other arm spawns
PHP as an external process; this one *is* PHP. That is precisely the choice volucer
rejects on purpose — "no PHP embedding, no FFI, `php`/`php-cgi`/`php-fpm` are always
spawned as external processes" is the first constraint in the plan — so this arm is the
number that constraint was traded against.

Everything else is held equal: the same `BenchApp`, the same page, the same twelve worker
threads, `max_requests`/`max_jobs`/`pm.max_requests` at 0 on all four servers, and the same
ini (512M, opcache on, timestamp validation off) applied through the mechanism each server
provides.

## The answer

| concurrency (12 workers, `/items`) | FrankenPHP | volucer `worker` | RoadRunner |
|---|---|---|---|
| 1 | 2,441 | 2,388 | 1,773 |
| 8 | 14,337 | **15,538** | 11,131 |
| 16 | 15,140 | **19,984** | 17,554 |
| 32 | 15,823 | **23,250** | 18,164 |

Median rps over 7 rounds, each round containing all three arms in rotated order, from a
verified-clean start. The spread across rounds was under 2% on every FrankenPHP cell.

Within one round, as ratios (median over the 7 rounds, `[min..max]`):

| concurrency | FrankenPHP / RoadRunner | volucer / RoadRunner | FrankenPHP / volucer |
|---|---|---|---|
| 1 | 1.381 `[1.350..1.401]` | 1.362 `[1.310..1.402]` | **1.018** `[0.969..1.054]` |
| 8 | 1.288 `[1.271..1.308]` | 1.399 `[1.380..1.442]` | 0.921 `[0.907..0.928]` |
| 16 | 0.876 `[0.852..0.884]` | 1.146 `[1.110..1.172]` | 0.759 `[0.747..0.776]` |
| 32 | 0.867 `[0.854..0.901]` | 1.277 `[1.261..1.332]` | 0.677 `[0.673..0.683]` |

**FrankenPHP and volucer are indistinguishable at concurrency 1, and FrankenPHP is
the slower of the three at 8, 16 and 32.** That c=1 cell is the one to read carefully: the
median ratio is 1.018 and its spread spans 1.00 — and it did so in every run of this arm,
before and after the client's CPU was accounted for. There is no evidence of a difference
either way. Its 393 µs median against volucer's 405 µs says the same thing.

The measured claim is therefore narrower than the first run of this arm suggested, and the
narrowing is the interesting part. An earlier attempt put FrankenPHP 5.9% ahead at
concurrency 1; re-measured with the load generator's own CPU accounted for and from a
verified-clean start, that lead is gone. What survives is the shape, and it is consistent in
every one of the 28 paired comparisons: **the arm with the interpreter inside its process
does not convert concurrency into throughput.** From 8 to 32 it gains 10.4% (14,337 →
15,823) where volucer gains 49.6% (15,538 → 23,250).

## It is not that the interpreter is too slow

The obvious explanation for a plateau — "the embedded interpreter simply costs more per
request, and 16k is what it costs" — is the wrong one, and CPU accounting says so. Twelve
seconds at concurrency 16, sampling `utime + stime` for the whole process tree out of
`/proc/<pid>/stat` (the integral, not a `top` snapshot):

| server | pids | server CPU-s | client CPU-s | cores used | rps |
|---|---|---|---|---|---|
| FrankenPHP | 2 | 85.99 | 6.26 | **7.17** | 15,262 |
| RoadRunner | 13 | 105.90 | 6.83 | 8.83 | 17,794 |
| volucer | 13 | 97.18 | 5.89 | 8.10 | 20,204 |

FrankenPHP serves the fewest requests per second *and* leaves the most cores idle: 7.17 of
12, against volucer's 8.10 at 33% higher throughput. So it is **not** CPU-bound. There is
capacity sitting unused while its throughput is capped, which is the signature of
queueing or dispatch rather than of compute — and the latency columns agree, because its
p50 at concurrency 32 is 1.89 ms against volucer's 1.28 ms.

Note the client column: `wrk` at concurrency 16 consumes 5.9–6.8 CPU-seconds too, about half
a core per twelve-worker arm. That is real and belongs in the accounting, though it is too
small to explain a 7.17-against-8.10 gap. (It was got wrong once: sampling the client after
`wrk` had exited produced a table of zeroes, because a dead process holds no CPU time.)

Why the ceiling exists is an open question, recorded in the plan rather than answered here.
The measurements above localise it to the server's own concurrency handling and not to the
interpreter's cost per request, and that is as far as the evidence goes.

## What was verified, and what it cost to get wrong

This arm's failure mode is silent, and it was worth a real amount of work to make it
audible. `php_server` runs a `worker` only where `match` says so, and its **default** is
"requests for a `.php` file". Everything else is handed to the ordinary per-request PHP
handler. Same binary, same worker script, same twelve threads, two Caddyfiles differing by
one directive, `GET /items` at concurrency 32:

| configuration | rps |
|---|---|
| `worker { match /* }` | 15,856 |
| no `match` (the default) | 662 |

A **24x gap** that no HTTP response can reveal: both return `200`, both contain the page
marker, both serve byte-identical bodies. A correct-looking 662 rps arm would have been
read as "embedding is much slower", not as "this arm is cold".

So the arm verifies its own model, positively. `frankenphp-worker.php` writes one line the
first time its request loop is actually asked to serve something, and the harness refuses
to measure the arm if the line is absent.

Two weaker checks were built first and **discarded, with their numbers**:

- **Timing.** A resident worker should answer an unloaded request faster than a cold one.
  It does, but not usefully: medians of 1.26 ms warm against 2.61 ms cold, and the
  best-case cold (1.96 ms) overlaps the worst-case warm (1.35 ms). Any threshold between
  them is a coin flip on a host shared with other work.
- **Worker-thread count from the log.** Every worker thread reports in — and *reaches its
  loop* — in **both** configurations, all twelve of them. The worker is real in both cases.
  It is simply never asked to serve anything.

Both are the same lesson the repository has already paid for once (hazard 28): a check
that cannot fail is not a check. The one that survives is the one that fails.

There are two other traps specific to this arm, both of which produced a broken arm before
they produced a number:

- **The release binary loads no `php.ini` at all.** `php_ini_loaded_file()` comes back
  empty, so without the Caddyfile's `php_ini` directive the whole arm would run PHP's
  compiled-in defaults — `memory_limit` 128M and `opcache.validate_timestamps` **on** —
  while every other arm ran 512M and off. The values are therefore read back from inside
  a worker thread, in the arm's own log, because a setting that looks right in a config
  file and is not applied is invisible from outside. Twelve lines, one per thread.
- **`STDERR` does not exist in this SAPI.** A worker's output *is* the HTTP response;
  there is no stderr stream. The first version of the worker wrote its diagnostic there
  and died with `Undefined constant "STDERR"` before reaching the request loop, which the
  server reports only as `worker ... has not reached frankenphp_handle_request()`.
  `error_log()` is the channel, and Caddy is already collecting it.

## Two confounds, stated rather than corrected

1. **A different PHP.** The release binary bundles PHP **8.5.11**; this host's other arms
   run **8.3.35**. There is no FrankenPHP build against 8.3, and building one would be
   measuring a PHP the project does not ship — so the version travels with every number
   above. It cuts both ways: the deficit at 8 upward may owe something to a runtime this
   new that has not had the tuning attention 8.3 has had, and the tie at concurrency 1 is
   a tie *despite* that difference.
2. **Two processes, not thirteen.** FrankenPHP reports 2 pids at concurrency 16 where the
   other two report 13. That is not a measurement artefact; it is the architecture. Its
   workers are threads, so nothing distinguishes one from the pool it belongs to — and
   nothing *can*, which is the point being measured.

## Reproducing

```bash
VARIANTS=franken,rr,new-req ROUNDS=7 CONC=1,8,16,32 DUR=5s ENDPOINTS=/items \
    bash scripts/ab-perf.sh
python3 scripts/ab-report.py ~/volucer-bench-run-ab/ab-rps.tsv
```

The arm needs the FrankenPHP release binary on the host:

```bash
curl -sL -o ~/bin/frankenphp \
    https://github.com/dunglas/frankenphp/releases/download/v1.13.0/frankenphp-linux-x86_64
chmod +x ~/bin/frankenphp
```

`FP` overrides the path. The binary is self-contained; there is nothing to build and no
Go toolchain needed. It needs no `php.ini` beside it either — do not add one, or "which
ini applied" becomes a question with two answers.

The raw rows are committed as [`franken-ab.tsv`](./franken-ab.tsv) and the console output,
including the per-round header and the model check for every round, as
[`franken-ab-run.log`](./franken-ab-run.log). No cell is published as a median of one
number: the `[min..max]` spreads above are computed from the 7 rounds inside the file.
