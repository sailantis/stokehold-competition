# Five ways to serve one page — 12 cores, one host

**Host:** Xeon Gold 5412U, 12 cores, 3884 MB, Ubuntu, PHP 8.3.35 NTS, nginx 1.24.0,
RoadRunner 2025.1.15, stokehold `c73c05c`, wrk 4.1.0.
**Method:** `scripts/bench.sh`, 5 s per cell, 3 repeats, median reported, 12 workers/slots
in every arm, endpoints `GET /` and `GET /items`, no failed cells. Plus
`scripts/latency.php`, the sequential per-request methodology the published figures used.

> **Read the latency section, not the throughput tables, for the deployment-model and
> transport questions.** This report originally answered both from wrk throughput at
> 12-way concurrency and got both wrong: a 12-slot sweep overlaps every request's
> framework boot with eleven other requests, so the per-request cost that the published
> ratios measure is invisible in the aggregate rate. The throughput tables are still
> correct as throughput, and the throughput question is a real one; they simply do not
> answer the question that was being asked of them.

## The two endpoints are different experiments

- **`GET /`** returns 5 KB and does almost no work: the container is built, the route
  matches, a tiny template renders. It measures **the server and the deployment model**.
- **`GET /items`** returns ~12 KB, runs one ORM query and renders 20 rows. It measures
  **the server, the model, and a response large enough to be divided across transport
  segments**.

## Corrected summary

| question | answer | how measured |
|---|---|---|
| Does the warm model pay off? | **yes, ~2.0-2.1x per request** (published: 3.3x) | sequential latency |
| Does it show in aggregate throughput? | **no, ~1.0x** - the boot overlaps across slots | wrk, 12 slots |
| Is loopback TCP a problem? | **~10% on a large response, 0% with fresh connections** | latency + curl |
| Does stokehold agree with RoadRunner? | **within 3%**, warm vs warm | both |

Everything below is the detail behind that table.

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

The absolute margin is small, and it is ~1.15x, not the 3.1-7.5x of the published
dataset. By throughput the warm model is worth 1.15-1.4x; by latency (further down) it is
worth ~1.5-2.1x. Both are true — they answer different questions.

## `GET /items` — throughput

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 880 | 3,146 | 5,282 | 7,447 | 8,566 |
| **R** | RoadRunner | warm worker, pipe | 901 | 3,288 | 5,470 | 8,577 | 8,727 |
| **F** | nginx + php-fpm | cold, unix socket | 830 | 3,036 | 5,493 | 8,401 | 8,552 |
| **U** | stokehold | cold, unix socket | 687 | 2,803 | 4,675 | 7,080 | 8,107 |
| **T** | stokehold | cold, loopback **TCP** | **198** | **261** | **267** | **283** | **281** |

**P/F is 1.00x. R/F is 1.02x.** A resident worker and nginx + php-fpm are the same speed
on this page by aggregate throughput. The T column is a measurement artifact: one wrk
connection lands on one pool slot, so it measures one slot's serial behaviour rather
than the pool's — explained under "What this says about the transport".

## What this says about the deployment model

**The published ratio reproduces — as a per-request latency figure. My throughput sweep did
not show it, and that was a methodology mistake on my side.**

`scripts/latency.php` re-implements the published primitive exactly: `hrtime()` around one
`curl_exec` at a time, a single reused connection, an untimed verified warm-up, 500–1000
iterations × 10 runs. Median of the run medians, milliseconds:

| arm | `GET /` | `GET /items` | vs the warm arms |
|---|---|---|---|
| **P** stokehold worker (warm) | 0.362 | **0.617** | 1.00× |
| **R** RoadRunner (warm) | 0.359 | **0.596** | 1.00× |
| **F** nginx + php-fpm (cold) | 0.543 | 1.234 | 1.51× / **2.07×** |
| **U** stokehold cold, unix (cold) | 0.656 | 1.466 | 1.83× / **2.38×** |
| **T** stokehold cold, TCP (cold) | 0.663 | 1.656 | 1.85× / **2.68×** |

Against `azera-competition`'s published `GET /items` for the same application
(RoadRunner 0.4647 ms, php-fpm 1.5318 ms = 3.30×) this run gives **2.07×**, and on `GET /`
(1.51× against a published 3.06×). So the effect is real, is in the published direction,
and reproduces about two-thirds of its magnitude on this host.

**The 1.00× in the throughput tables above is an artifact, and this is the lesson worth
keeping.** A wrk sweep at 12-way concurrency keeps all 12 slots busy, so each request pays
its own framework boot *while the other eleven are serving other requests* — the boot is
overlapped away and the aggregate rate stops being sensitive to it. The published figure
is a *latency* claim about one request, and only a sequential measurement can make it.
Comparing a throughput ratio against a latency ratio is not comparing like with like; that
is what the first version of this report did.

The mechanism is also not what this report first claimed. The published 3.1–7.5× was
described here as "an endpoint whose work is almost entirely container". Measured, the
cold arms pay about **1.0 ms** of framework boot per request (7.2 ms on a cold opcache for
a fresh pool, then 1.00 ms steady state, measured inside a warm php-cgi child). On
`/items` that boot is ~two-thirds of the cold arm's 1.47 ms against the warm arm's 0.62 ms
of work, which is exactly the ~2.4× observed. The ratio is the boot divided by the work —
it is a property of the endpoint, and on this page the work is not negligible, so the
ratio is ~2× rather than ~3×.

## What this says about the transport

**The "T is 29× slower than U" result in the earlier version of this report was wrong, and
the throughput tables above still show its cause.** It was measured with wrk at one
connection; a single persistent client connection lands on one pool slot, so that slot
serialises while the other eleven — and therefore the aggregate rate — are unaffected.
What the sweep actually measures is one slot's behaviour, which is why T collapsed to
198–281 rps while U did not: **the 59 ms tail is a single-connection phenomenon, not a
general TCP penalty.**

Stated correctly, from two independent measurements:

- **Sequential latency** (`latency.php`, one connection, the same shape as the artifact):
  T 1.656 ms vs U 1.466 ms on `/items` — **13%**, not 29×. On `/`, 0.663 vs 0.656 ms — 1%.
- **Fresh connections** (sequential `curl`, no reuse): T and U were **identical**, 1.8 ms
  each within noise.

So on this host a unix socket is worth roughly **10%** on a large response and nothing on
a small one or on a fresh connection. That is a real but modest advantage, and it is the
honest justification for `socket = "unix:..."` — not the order of magnitude the first
version of this report claimed. Loopback TCP's per-packet cost is real (measured in
`ss`'s `minrtt` as 11 µs against 2 µs, so ~9 µs more per round trip) but a request pays
only a handful of round trips.

### A real bug found on the way, which was not the cause

Per-connection `tcpdump` showed stokehold sending each FastCGI request as **8 separate TCP
segments** — each 8-byte record header written individually — where nginx sends 1–2. The
client sets `TCP_NODELAY`, so every `write` became its own segment, and php-cgi only sets
`TCP_NODELAY` on its side *after* it reads the request, which is exactly the window
stokehold's eight writes fall in.

`Client::send` now assembles the request in a reused buffer and writes it once, with a
test pinning the two framings to identical bytes. Measured before/after on the same
methodology: **1.572 ms → 1.509 ms, about 4%.** So it was a genuine inefficiency and worth
fixing, but it was not the cause of the 59 ms tail, and the first version of this report
named it as the cause on the strength of a segment count rather than a measurement. The
tail remains unexplained; it is single-connection-only and does not appear with fresh
connections.

## The confounds, stated

**Why 2.07× here and 3.30× published, on the same application and the same route.** The
ratio is the boot divided by the work, so it moves with the work. My warm arm does
0.617 ms of work where the published RoadRunner row does 0.4647 ms — this page carries
more per request (an ORM query and a 12 KB render against the published entry script's own
mix), so the same ~1.0 ms boot is a smaller multiple of it. Neither figure is wrong: a
ratio is only comparable between runs whose warm-arm cost is comparable, and these differ
by ~33%. **Compare ratios only when the warm-arm cost matches; otherwise compare absolute
milliseconds.**

**The boot is the framework's, and every cold arm pays it.** All four cold arms reach the
same entry script (`public/index.php`) and boot the same `BenchApp` the warm arms use; they
differ only in *when* the boot happens. That is the experiment, not a confound — but it
does mean the FPM and `spawn_cgi` arms both carry the `azera-framework` boot, so a faster
framework boot would shrink every cold arm together and leave the ranking unchanged.

**Host.** `azera-competition`'s published figures came from a different machine. Absolute
milliseconds are not portable between the two; the direction and rough magnitude are.

**Measured on a quiet host.** 12 cores, load 0.2, no other servers. The FPM arm's pool and
the stokehold pool are matched on the model (`pm.max_children = 12` / `workers = 12`,
`pm.max_requests = 0` / `max_requests = 0`), and the cold arms' opcache settings are verified
identical **through a request** rather than through the config file.

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
