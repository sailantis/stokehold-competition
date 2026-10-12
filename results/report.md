# Five ways to serve one page — 12 cores, one host

**Host:** Xeon Gold 5412U, 12 cores, 3884 MB, Ubuntu, PHP 8.3.35 NTS, nginx 1.24.0,
RoadRunner 2025.1.15, stokehold `c406a49`, wrk 4.1.0.
**Method:** `scripts/bench.sh`, 5 s per cell, 3 repeats, median reported, 12 workers/slots
in every arm, endpoints `GET /` and `GET /items`, no failed cells. Plus two extra passes:
`scripts/latency.php` (the sequential per-request methodology the published figures used)
and `scripts/crossover.php` (the same latency at concurrency 1..16).

> **There are three passes and they answer three different questions.** A wrk sweep holds
> concurrency at the slot count and reports what the host can push; `latency.php` holds it
> at 1 and reports what one request costs; `crossover.php` sweeps it and reports where the
> model advantage sits at each load. This report has been wrong in *both* directions by
> reading one pass as another — first claiming the warm model was worth nothing in
> throughput (it was a config bug on the unwrapped arms), then reading a throughput ratio
> against a published latency ratio. The three passes now agree with each other, and the
> agreement is the result, not any single table.

## The two endpoints are different experiments

- **`GET /`** returns 5 KB and does almost no work: the container is built, the route
  matches, a tiny template renders. It measures **the server and the deployment model**.
- **`GET /items`** returns ~12 KB, runs one ORM query and renders 20 rows. It measures
  **the server, the model, and a response large enough to be divided across transport
  segments**.

## Corrected summary

| question | answer | how measured |
|---|---|---|
| Does the warm model pay off? | **yes, ~2.0x per request** (published: 3.3x) | sequential latency |
| Does it show in aggregate throughput? | **yes on `/`, ~1.6-1.9x; and 1.9x on `/items` at c=32** (originally ~1.0x, which was a bug) | wrk, 12 slots |
| At what load does it stop paying? | **it does not, within 1..16** - flat ~2.0x | crossover |
| Why does the cold model idle 16% of the cores? | **it costs 1,063 us of CPU per request against 666** - a duty cycle, not headroom | CPU accounting |
| Is loopback TCP a problem? | **no - T and U agree to 3%** (a 40 ms/request stall in stokehold's client was) | latency + wire |
| Which transport should I use? | **either** - keep `unix:` for permissions, not speed | both |
| Does stokehold agree with RoadRunner? | **within 10%**, warm vs warm | both |

Everything below is the detail behind that table.

## `GET /` — the server and the model

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 2,921 | 11,569 | 20,523 | 30,204 | 30,855 |
| **R** | RoadRunner | warm worker, pipe | 3,123 | 11,748 | 20,770 | 35,076 | 37,013 |
| **F** | nginx + php-fpm | cold, unix socket | 1,866 | 6,664 | 12,004 | 18,807 | 18,576 |
| **U** | stokehold | cold, unix socket | 1,543 | 5,777 | 9,537 | 14,498 | 16,497 |
| **T** | stokehold | cold, loopback TCP | 1,514 | 5,777 | 9,567 | 14,186 | 16,143 |

Ratios at c=32: **P/F 1.66×**, **R/F 1.99×**, **T/U 1.02×**.

Two things follow. The piped warm worker (P) and RoadRunner (R) agree to within ~20%,
which is what makes the warm half of the comparison credible — two independent servers, one
model. And on this endpoint **transport is irrelevant**: 1.0× T/U. The piped worker's
advantage comes from not booting the framework, not from the pipe.

## `GET /items` — throughput

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 1,564 | 6,013 | 10,172 | 14,826 | 16,329 |
| **R** | RoadRunner | warm worker, pipe | 1,791 | 6,560 | 11,277 | 17,598 | 18,258 |
| **F** | nginx + php-fpm | cold, unix socket | 839 | 3,068 | 5,531 | 8,491 | 8,540 |
| **U** | stokehold | cold, unix socket | 681 | 2,800 | 4,738 | 7,173 | 8,161 |
| **T** | stokehold | cold, loopback TCP | 665 | 2,790 | 4,752 | 7,096 | 7,989 |

Ratios at c=32: **P/F 1.91×**, **R/F 2.14×**, **T/U 1.02×**.

An earlier version of this table showed **P/F and R/F at 1.00× and 1.02×** — "a resident
worker and nginx + php-fpm are the same speed on this page". That was wrong, and the cause
was a configuration difference on the one pair of arms nothing had wrapped: P and R ran a
bare `php worker.php`, so they were the only arms exposed to what the host's CLI PHP
happened to have installed. With xdebug loaded the two warm arms ran at roughly half speed;
with every arm given the same PHP they roughly doubled and the cold arms did not move. See
"What this says about the deployment model" for the before/after.

The T column in the *first* version of this file read **198–281 rps** on `/items` and was
called a measurement artifact of the single-connection sweep. It was not an artifact: T was
stalling 40 ms per request in stokehold's client, which is now fixed, and T now sits within
2% of U at every concurrency.

## What this says about the deployment model

**The published ratio reproduces — as a per-request latency figure.**

`scripts/latency.php` re-implements the published primitive exactly: `hrtime()` around one
`curl_exec` at a time, a single reused connection, an untimed verified warm-up, 1000
iterations × 10 runs. Median of the run medians, milliseconds:

| arm | `GET /` | `GET /items` | vs the warm arms |
|---|---|---|---|
| **P** stokehold worker (warm) | 0.389 | **0.648** | 1.00× |
| **R** RoadRunner (warm) | 0.362 | **0.591** | 1.00× |
| **F** nginx + php-fpm (cold) | 0.570 | 1.228 | 1.57× / **2.08×** |
| **U** stokehold cold, unix (cold) | 0.697 | 1.475 | 1.93× / **2.50×** |
| **T** stokehold cold, TCP (cold) | 0.708 | 1.495 | 1.96× / **2.53×** |

Against `azera-competition`'s published `GET /items` for the same application
(RoadRunner 0.4647 ms, php-fpm 1.5318 ms = 3.30×) this run gives **2.08×**, and on `GET /`
(1.57× against a published 3.06×). So the effect is real, is in the published direction,
and reproduces about two-thirds of its magnitude on this host.

**T and U now agree to 1%.** They did not before: T was 1.656 ms against U's 1.466 ms
because of a 40 ms-per-request stall in stokehold's own client, not because of the
transport. See "What this says about the transport" — that was the single largest
correction in this report's history, and it moved T by 34×.

The published 3.1–7.5× was described here as "an endpoint whose work is almost entirely
container". Measured, the cold arms pay about **1.0 ms** of framework boot per request
(7.2 ms on a cold opcache for a fresh pool, then 1.00 ms steady state, measured inside a
warm php-cgi child). On `/items` that boot is ~two-thirds of the cold arm's 1.47 ms against
the warm arm's 0.65 ms of work, which is the ~2.3× observed. The ratio is the boot divided
by the work — it is a property of the endpoint, and on this page the work is not
negligible, so the ratio is ~2× rather than ~3×.

### The throughput question has a different answer, and it is also real

An earlier version of this report said the warm model showed **~1.0×** by aggregate
throughput. That was measured while the two warm arms were running an unwrapped `php`,
exposed to a host whose CLI PHP had xdebug loaded. Once every arm was given the same PHP,
the warm arms roughly doubled and the cold arms did not move:

| `/items`, conc 32 | with the unwrapped CLI PHP | with every arm wrapped | factor |
|---|---|---|---|
| **P** warm worker | 8,566 | **16,329** | 1.91× |
| **R** RoadRunner | 8,727 | **18,258** | 2.09× |
| **F** nginx + php-fpm | 8,552 | 8,540 | **1.00×** |
| **T/U** spawn_cgi | 8,107 / 7,915 | 7,989 / 8,161 | 1.00× |

So the warm model is worth ~1.9× by throughput too, on the same route where a previous
version of this report found no difference at all. That earlier "1.0×" was a configuration
artifact on the one pair of arms nobody had wrapped — hazard 28's pattern exactly, a
difference of ini mistaken for a difference of server.

## What this says about the transport

**Loopback TCP and a unix socket are equivalent. T and U agree to 3% at every
concurrency in every pass, and there is no transport penalty to explain.**

This section has been wrong three times, so it is worth stating what the answer finally
rested on. An earlier version of this report claimed T was **29× slower** than U on
`/items`. That was measured with `wrk` at one connection, and one wrk connection lands on
one pool slot: the column measured one slot serialising while the other eleven and the
aggregate rate were unaffected. A second version put the penalty at ~10% (13% on `/items`,
1% on `/`, identical with fresh connections) and attributed it to loopback TCP's per-packet
cost, which `ss` does show — `minrtt` 11 µs against 2 µs.

Both were measuring a real effect and misnaming its owner. `spawn_cgi` over TCP was
**stalling 40 ms per request** in stokehold's own client, and the mechanism is:

- A Linux `php-cgi` child **never sets `TCP_NODELAY`**. `main/fastcgi.c` guards that call
  with `req->keep && req->tcp`, and `req->tcp` is assigned only under `#ifdef _WIN32`
  (line 897), so on Linux it keeps the zero `calloc` gave it and the call is never reached.
  The child runs with Nagle enabled.
- That is harmless on its own and ruinous here because php-cgi flushes in **8 KiB chunks**
  (`out_buf[1024*8]`). A response larger than 8 KiB leaves a short final segment, and Nagle
  withholds it until the previous data is acknowledged.
- The connection is keep-alive, so Linux's ACK is a **delayed ACK — 40 ms on this host**.
- The withheld tail is still unacknowledged when the *next* request arrives, so the stall
  repeats on every request rather than only the first. That is also why a 5 KB page was
  slow: the previous response's tail is permanently outstanding.

Measured on one slot, sequential, `/items`:

| | per request | `TcpExtDelayedACKs` |
|---|---|---|
| T over loopback TCP, before | **42.005 ms** | 10,054 |
| T over loopback TCP, after | **1.238 ms** | **0** |
| U over a unix socket (control) | 1.219 ms | 0 |

42.005 ms with a 0.05 ms spread is a timer, not a rate: 40 ms of delayed ACK plus ~2 ms of
work. The wire trace agreed, showing php-cgi's trailing 1728-byte segment leaving **10 µs
after** stokehold's ACK arrived 40.7 ms after the data.

The fix is receiver-side and is in `stokehold-fcgi`: `TCP_QUICKACK` immediately before each
read on a TCP backend. The kernel clears the flag after using it and after every `recv`, so
it is re-armed per read rather than set once at connect time, and it takes effect from the
next read — which is the read whose ACKs would otherwise be delayed.

**This was stokehold's bug, not the transport's**, and the earlier evidence already said so:
nginx + php-cgi over TCP, the same server and the same transport with a different client,
measured a healthy 848 rps in an isolation test all along.

### The 8-segment write, which was real and was not the cause

Per-connection `tcpdump` showed stokehold sending each FastCGI request as **8 separate TCP
segments** — each 8-byte record header written individually — where nginx sends 1–2.
`Client::send` now assembles the request in a reused buffer and writes it once, with a test
pinning the two framings to identical bytes. Measured before/after on the same methodology:
**1.572 ms → 1.509 ms, about 4%.** A genuine inefficiency, worth fixing, and not the cause —
the first version of this report named it as the cause on the strength of a segment count
rather than a measurement.

The lesson from all three attempts, kept because it would have skipped all of them: **a
number that is suspiciously round in wall time is a timer, not a rate.**

## The crossover — latency under concurrency

The table above holds concurrency at 1 and the sweep holds it at 12. Neither answers the
question a deployment faces: at what load does the resident worker's advantage stop being
visible. `scripts/crossover.php` holds it at each of 1..16 with N closed-loop client
processes, one per connection, each running the same blocking loop `latency.php` uses.

Median of 3 runs x 500 iterations per client, milliseconds. The ratio column is R/F.

| conc | P stokehold | R RoadRunner | F nginx+php-fpm | U stokehold unix | T stokehold TCP | R/F |
|---|---|---|---|---|---|---|
| 1 | 0.645 | 0.595 | 1.240 | 1.464 | 1.490 | **2.08×** |
| 2 | 0.646 | 0.580 | 1.177 | 1.348 | 1.381 | 2.03× |
| 4 | 0.672 | 0.616 | 1.231 | 1.358 | 1.370 | 2.00× |
| 8 | 0.786 | 0.720 | 1.377 | 1.595 | 1.556 | 1.91× |
| 12 | 0.931 | 0.802 | 1.528 | 1.895 | 1.910 | 1.91× |
| 16 | 1.019 | 0.937 | 1.864 | 2.111 | 2.086 | **1.99×** |

**The advantage does not cross over.** It is ~2.0× at concurrency 1, dips to ~1.9× in the
middle, and is back to ~2.0× at 16. That is the opposite of the intuition that a
per-request boot must eventually be hidden by concurrency, and the CPU numbers below are
why: the cold arm saturates its CPU budget at ~8,500 rps while the warm arm reaches
~16,000, so the cold arm is the one already queuing and the gap has no reason to close.

On `/` the same pass gives a flat **~1.5×** (P/F) and **~1.64×** (R/F) at every concurrency.

Note that the cold arm's *absolute* penalty is much larger on `/items` (0.58 ms) than on
`/` (0.18 ms), which is more than a constant boot would explain. The cold arm appears to
pay in proportion to what the request touches, plausibly because autoloading and lazy class
resolution follow the code path. That is an inference from these numbers, not a separate
measurement, and it is recorded as such.

**Caveat, stated rather than hidden:** past concurrency 12 the *client* is the limit. The N
client processes share the same 12 cores as the servers, and every latency in the table
rises roughly linearly with N — including the two warm arms, which have no boot to pay. So
the absolute values above 12 are not trustworthy, and above 12 even the ratios are muddied
once clients take scheduled time from server slots. A second machine to generate load would
fix it; one is not available here.

The first version of this measurement was wrong in this project's usual way. Driving N
handles from one process with `curl_multi`, it reported concurrency 2 as *exactly* 2× the
latency of concurrency 1 on three unrelated servers, with throughput flat between them —
which no real server does. Two client bugs: `curl_getinfo` read after
`curl_multi_remove_handle` (every status 0), and `curl_multi_select($multi, 0.05)` whose
timeout is 50 **milliseconds**, a retry floor that cost 1,516 rps where `wrk` got 3,211.
A hand-tuned timeout would have fixed it; running N processes instead removes the class of
bug, and it agrees with `latency.php` to 0.1% at concurrency 1 (0.5963 vs 0.596 ms).

## The cold model's real cost is CPU, and it is a duty cycle

A saturated run was observed using only ~84% of the 12 cores. The obvious explanation is
wrong: raising `workers` from 12 to 24 to 36 at concurrency 32 left throughput flat and
slightly lower (7,634 / 7,738 / 7,250 rps), so the pool was never the limit.

Measuring CPU per request explains the idle time exactly:

| arm, conc 32 | rps | cores used | % of 12 | **CPU per request** |
|---|---|---|---|---|
| P worker (warm) | 15,563 | 10.37 | 86% | 666 µs |
| T spawn_cgi (cold) | 7,900 | 8.40 | 70% | **1,063 µs** |

Both close arithmetically: `15,563 × 666 µs = 10.37 cores` and `7,900 × 1,063 µs = 8.40
cores`. The per-request model costs ~1.06 ms of CPU per request against ~0.67 ms, a ratio
of 1.60 — and since the cold arm's 1.06 ms is its entire budget, adding workers cannot make
it faster. The idle cores are not headroom; they are the cost of booting PHP and the
framework on every request.

The remaining 16% is the other half of the same story. `php-cgi` is single-threaded and its
request cycle is not all CPU: some of it is waiting on its own socket for the next request.
Twelve such processes leave a core or two unscheduled, and no amount of client concurrency
fixes that, because concurrency is capped by the 12 children — a php-cgi child serves one
request at a time. The cold model has a duty cycle, and its ceiling is the pool size times
that duty cycle.

## The confounds, stated

**Why ~2× here and 3.30× published, on the same application and the same route.** The ratio
is the boot divided by the work, so it moves with the work. My warm arm does 0.595 ms of work
where the published RoadRunner row does 0.4647 ms — this page carries more per request (an
ORM query and a 12 KB render against the published entry script's own mix), so the same
~1.0 ms boot is a smaller multiple of it. Neither figure is wrong: a ratio is only
comparable between runs whose warm-arm cost is comparable, and these differ by ~28%.
**Compare ratios only when the warm-arm cost matches; otherwise compare absolute
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
