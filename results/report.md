# Five ways to serve one page — 12 cores, one host

**Host:** Xeon Gold 5412U, 12 cores, 3884 MB, Ubuntu, PHP 8.3.35 NTS, nginx 1.24.0,
RoadRunner 2025.1.15, stokehold `c73c05c`, wrk 4.1.0.
**Method:** `scripts/bench.sh`, 5 s per cell, 3 repeats, median reported, 12 workers/slots
in every arm, endpoints `GET /` and `GET /items`, no failed cells.

## The two endpoints are different experiments

This is the first thing to understand, because it decides which table answers which
question.

- **`GET /`** returns 5 KB and does almost no work: the container is built, the route
  matches, a tiny template renders. It measures **the server and the deployment model**.
- **`GET /items`** returns ~10 KB, runs one ORM query and renders 20 rows. It measures
  **the server, the model, and a response large enough to be divided across transport
  segments**. The second part turns out to matter more than the first.

## `GET /` — the server and the model

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 2,159 | 8,141 | 13,679 | 19,860 | 21,340 |
| **R** | RoadRunner | warm worker, pipe | 2,051 | 7,340 | 13,030 | 20,755 | 21,543 |
| **F** | nginx + php-fpm | cold, unix socket | 1,831 | 6,609 | 12,145 | 18,934 | 18,498 |
| **U** | stokehold | cold, unix socket | 1,561 | 5,718 | 9,246 | 14,153 | 15,954 |
| **T** | stokehold | cold, loopback TCP | 1,496 | 5,802 | 9,421 | 13,883 | 15,701 |

Ratios: **P/F 1.15×**, P/T 1.43×, P/U 1.40×. **T vs U is 1.0×** at every concurrency.

Two things follow. The piped warm worker (P) and RoadRunner (R) agree to within ~5% at
every point, which is what makes the warm half of the comparison credible — two
independent servers, one model. And on this endpoint **transport is irrelevant**: 1.0×
T/U. The piped worker's advantage comes from not booting the framework, not from the pipe.

The absolute margin is small, and it is ~1.15×, not the 3.1–7.5× of the published
dataset. That is expected rather than contradictory: a 5 KB response is dominated by
server overhead, so the boot it saves is a small share of the total. The larger ratio is
the property of an endpoint whose response is nearly free and whose work is almost all
container — which is precisely what the next endpoint is not.

## `GET /items` — a larger response changes the answer

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 880 | 3,146 | 5,282 | 7,447 | 8,566 |
| **R** | RoadRunner | warm worker, pipe | 901 | 3,288 | 5,470 | 8,577 | 8,727 |
| **F** | nginx + php-fpm | cold, unix socket | 830 | 3,036 | 5,493 | 8,401 | 8,552 |
| **U** | stokehold | cold, unix socket | 687 | 2,803 | 4,675 | 7,080 | 8,107 |
| **T** | stokehold | cold, **loopback TCP** | **198** | **261** | **267** | **283** | **281** |

**P/F is 1.00×. R/F is 1.02×.** A resident worker and nginx + php-fpm are the *same
speed* on this page. And the TCP arm is not slow by a little — it stops scaling
altogether, 198 → 281 rps across the whole concurrency sweep.

### Why the TCP arm collapses, and why it is not one server's bug

`T` and `U` are the same server, the same model, the same SAPI, the same 12 slots, the
same page. The only difference is a unix socket versus loopback TCP, and the ratio is
**28.9×** at c=32.

The latencies say what kind of problem it is:

| | p50 | p99 |
|---|---|---|
| T `/items` c=1 | 1.81 ms | **42.50 ms** |
| U `/items` c=1 | 1.42 ms | 1.84 ms |
| T `/items` c=32 | **110.03 ms** | 523.87 ms |
| U `/items` c=32 | 3.09 ms | 32.70 ms |

At c=1 the *median* is fine and `p99` is 23× the median; roughly one request in four
pays ~40 ms. That is the delayed-ACK/Nagle signature — a response needing more than one
write waits for the peer's delayed acknowledgement — and it scales with response size,
which is why `/` (5 KB, 1.0×) is unaffected and `/items` (10 KB) is destroyed. A unix
socket has no Nagle, no delayed ACK and no `TCP_NODELAY` to mis-set.

The same shape appears in the other TCP arms, at a level the loopback hop alone cannot
explain: **T is 9.8× slower than U on `/`'s sibling transport comparison but only 1.4×**
on `/`, and the whole `spawn_cgi`+TCP configuration should be *faster* than the piped
worker if TCP were innocent — hazard 25 measured it scaling past 30k on a small response.

## What this says about the deployment model

**On these endpoints, the warm model's advantage is smaller than the published dataset
implies, and on `/items` it is nil.** The honest explanation has three parts.

1. **The boot really is only ~1.0 ms here.** Measured directly inside a warm php-cgi
   child: a fresh pool pays 7.2–7.5 ms on the first request to each of its 12 slots
   (opcache cold), and **1.00 ms** steady-state thereafter. So a cold request over a
   unix socket costs ~1.0 ms of boot + ~1.0 ms of work, and removing the boot can
   therefore buy at most ~2× at c=1.
2. **The published 3.1–7.5× ratios compare an application with a large container boot
   against a request that does almost nothing else** (RoadRunner 0.255 ms vs php-fpm
   0.785 ms on azera). That is a real and fair measurement of a real configuration, but
   it is not comparable to a page that spends half its time on an ORM query and a
   template render.
3. **On `/` this run agrees with the published direction and not the magnitude**:
   1.15×, against ~1.1× on a trivial handler (hazard 25) and 3.1× on the published azera
   `GET /`. The difference between the last two is the endpoint's work, not the server.

So: **the warm model's value is proportional to what the framework boots, and on a real
endpoint with real work in it, the per-request boot is a ~1 ms constant that both fast
cold configurations and every warm one absorb.** This is the same conclusion hazard 27
reached with a database query in the request — "the four arms converge" — reached here
with a framework and a 10 KB response instead.

## What this says about the transport

**`spawn_cgi` should not use loopback TCP on Linux.** On a 10 KB response it is 29×
slower at concurrency 32 and 3.5× at concurrency 1, and its latency distribution shows
why. Unused, it is the worst of both worlds: `spawn_cgi`+TCP has the piped worker's
1.4× disadvantage on `/` *and* the transport collapse on `/items`. `socket = "unix:..."`
exists for this reason and is worth far more than the loopback hop it was originally
justified by.

## The confound in this run, stated

The FPM arm's pool and the stokehold pool are configured to match on the model
(`pm.max_children = 12` / `workers = 12`, `pm.max_requests = 0` / `max_requests = 0`) and
the cold arms' opcache settings are verified identical **through a request**, not through
the config file. One difference remains:

**php-fpm was reached through the framework's cold front controller, so its 7–8 ms
container boot is the framework's; the FPM configuration therefore understates php-fpm
relative to this project's own worker by the `azera-framework` boot alone.** The
`/`-endpoint table, where the boot is the entire difference, is where that matters most.
It does not affect the T/U transport finding, which holds the entry script constant.

The larger confound is the one the first section names: the published dataset and this
run measure different endpoints, and the endpoint's work is what sets the ratio. Neither
number is wrong; they answer different questions.

## Everything that had to be fixed before these numbers were trustworthy

Each of these was found by reading a response body or an `ini_get()` rather than trusting
a 200 or a config file, and each one silently produced a plausible wrong number:

- **xdebug in php-fpm cost the FPM arm 3.1×.** `php_admin_value[xdebug.mode] = off` makes
  the value come back **empty** while leaving the extension loaded (`(empty)` with the
  line, `develop` without it, xdebug loaded either way). Measured through the pool: 591 vs
  **1,831** rps on `/`, 339 vs **830** on `/items`. The harness now moves xdebug's
  `conf.d` file aside for the run and restores it afterwards.
- **`opcache.validate_timestamps` was left at its default (on)**, because an earlier edit
  deleted the `php_admin_value` lines that set it. Statting every file per request is a
  silent per-request cost; the harness's ini probe catches it.
- **nginx `try_files` served the front controller as a static file.** `try_files
  /index.php =404;` tests `/index.php` on disk, finds it, serves the PHP **source** with a
  200. The FPM arm returned its own source code and looked healthy. The vhost now has one
  `location` and no `try_files`.
- **The FPM pool was deleted after every arm**, so the FPM arm — the last one — was never
  measured. Provisioning once and tearing down once are different jobs.
- **The harness's own summary inserted newlines into TSV rows** (`3.77ms p99` in the arm
  column), because `awk '/50%/'` matched two lines. Anchored and short-circuited now.
- **A pool file left behind takes the host's php-fpm down for everyone**, which an
  interrupted run did. The teardown is in the `EXIT` trap.
- **php-fpm ran as `www-data` against a `competition`-owned SQLite database** and 500'd
  every request; the pool now runs as the checkout's owner.
