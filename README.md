# stokehold-competition

Five ways to serve **one page on one machine**, measured identically.

This exists to answer a question the earlier benchmarks could not. On a handler
that returns a few dozen bytes, every deployment model lands within ~10% of every
other — a trivial request has nothing to keep warm, so the worker model's whole
premise is invisible. The hypothesis here is that the gap is proportional to what
the application has to boot, and the fix is to serve a page that actually builds a
framework container.

The page is `GET /items`: one SQLite query through the azera ORM, rendered by a
ClarityEngine template, through a controller with middleware. It is the cheapest
route that still boots the container.

## The five arms

| arm | server | model | transport |
|---|---|---|---|
| **P** | stokehold `worker` | warm — framework booted once | pipe |
| **T** | stokehold `spawn_cgi` | cold — framework booted per request | loopback TCP |
| **U** | stokehold `spawn_cgi` | cold — framework booted per request | unix socket |
| **R** | RoadRunner `worker` | warm — framework booted once | pipe |
| **F** | nginx + php-fpm | cold — framework booted per request | unix socket |

Five arms is not five questions. Each pair isolates one variable:

- **T vs U** — the transport. Same server, same model, same SAPI, same page. A
  difference here is the transport and nothing else.
- **P vs T/U** — the deployment model. A difference here is what the framework
  boot costs when it is paid per request instead of once.
- **F vs T/U** — the server implementation at the same cold model.
- **P vs R** — the server implementation at the same warm model.

**One confound is stated rather than hidden:** P is both warm *and* piped, so
P-vs-T/U mixes the model with the transport. That mixed comparison is still the
one that matters commercially — it is the two deployment models as they are
actually deployed — but a claim about the transport alone has to come from T vs U,
where the model is held equal. The stokehold plan already measured pipe and TCP as
identical to concurrency 8 on a trivial handler, so the pipe-specific cost is not
expected to be large; this repository is what checks that on a real page.

## The conclusion is platform-dependent, and Windows inverts it

The published run is Linux, and on Linux the warm arm wins by the margin the
hypothesis predicted. **On Windows with a pipe-transported worker it loses**, and the
reason is not the server:

| what PHP is reading | median | p95 |
|---|---|---|
| a **pipe** | **~8 ms** | **~15.4 ms** |
| a **socket** | **~0.09 ms** | — |

PHP's Windows stream layer takes ~100× longer to return from a blocking read on a
pipe than on a socket, and the cost is paid *per request*. So on Windows arm P —
warm, but pipe-transported — is slower than arms T/U, which are cold but
socket-transported, and the warm/cold comparison inverts. Nothing stokehold does
causes it: a Rust process reading the identical pipe returns in 0.010 ms, and
RoadRunner measured 15.15 ms against stokehold's 15.24 ms on the same host — two
independent servers and two independent SDKs agreeing to 0.6%.

**So `arm P` on Windows is not the deployment model's value; it is the pipe's
cost.** stokehold has a `transport = "socket"` option for this (see its README and
plan hazard 46), and with it the same warm arm measures **0.72 ms median against
15.24 ms on the pipe** — 21× faster, a 0.06 ms spread across 9 runs, and the two
ranges are disjoint by two orders of magnitude. That is back in line with the Linux
figure, which is what shows the difference is the transport rather than the
platform. To reproduce the Windows comparison:

```bash
# the worker follows STOKEHOLD_WORKER_SOCKET when the server sets it
# (Stokehold\Worker::connect()), so only the config differs
transport = "socket"    # [backends.app]
```

`worker.php` uses `Stokehold\Worker::connect()` for exactly this reason: it drives
both transports with no PHP-side change, so the arm can be measured on either. The
SDK version pinned in `composer.json` must include `connect()`, since a worker that
calls a method the pinned SDK does not have is a startup fatal error rather than a
degraded path.

**The inversion is the pipe's doing, and it is worth saying what it is not.** It is
not Windows making FastCGI good. `spawn_cgi` measured on the same host peaks at
**~1,730 rps against the resident worker's ~9,700 on `/items`** — about 5.6× — so once
the warm arm is not crippled by the pipe it wins on Windows by a *larger* margin than
the Linux arms show (8,385 against 19,504, or 2.3×). Windows is slower for both
deployment models; it is the cold one that pays much more of the penalty:

| metric (`GET /items`) | Linux, 12 cores, idle | Windows, 6c/12t, 20–30% busy | ratio |
|---|---|---|---|
| resident worker, sequential p50 | 0.556 ms | 0.82 ms | 1.5× |
| FastCGI, sequential p50 | 1.52 ms | 4.6 ms | **3.0×** |
| peak throughput, resident worker | 19,504 rps | 9,717 rps | 0.50× |
| peak throughput, FastCGI | 8,385 rps | 1,728 rps | **0.21×** |

So the deployment-model conclusion is not platform-specific after all — the resident
worker wins on both, and wins *more* easily on Windows. What was platform-specific was
the pipe.

## FastCGI on Windows is fine, and its transport does not matter

There is no Windows counterpart to the Linux arm F: `php-fpm` does not exist on
Windows, so neither the `external` nor the `spawn_fpm` backend can run there, and
**`spawn_cgi` is the only FastCGI path**. That makes Windows the one place the
FastCGI transport pair can be compared directly, because `php-cgi -b` binds a
**named pipe** for a `\\.\pipe\` address and loopback TCP for a `host:port` one.

Three arms interleaved within each concurrency level (so background drift cannot be
charged to whichever arm ran during a busy moment), 3 rounds of 5 s per cell, 12
slots each, **0 errors and 0 worker respawns in all 27 runs**:

| conc | `spawn_cgi` + **named pipe** | `spawn_cgi` + TCP | `worker` + socket | worker/pipe | worker/tcp | pipe/tcp |
|---|---|---|---|---|---|---|
| 1 | 274 rps | 267 rps | 1,201 rps | 4.38× | 4.50× | 1.028 |
| 12 | 1,641 rps | 1,631 rps | 9,717 rps | 5.92× | 5.96× | **1.006** |
| 32 | 1,728 rps | 1,693 rps | 7,716 rps | 4.46× | 4.56× | 1.021 |

**The FastCGI transport is a non-question — 0.6–2.8% apart at every level** — and the
CPU column says why:

| conc | worker CPU/req | fcgi-pipe CPU/req | fcgi-tcp CPU/req |
|---|---|---|---|
| 1 | 0.93 ms | 5.27 ms | 4.25 ms |
| 12 | 1.16 ms | 4.58 ms | 4.80 ms |
| 32 | 1.06 ms | 4.73 ms | 4.86 ms |

A `spawn_cgi` request costs **5×** the CPU of a worker request, because the CGI SAPI
pays the framework boot every time. The transport difference is 42 µs on a 4.6 ms
request (hazard 45 measured 168 µs against 211 µs over the FastCGI exchange alone) —
about 0.9%, which is the size of the ~1.5% latency difference above. **Hazard 45
extrapolated that 42 µs to "an end-to-end effect of about 8%"** by assuming the
exchange was a large share of a request. It is not, and the prediction is not borne
out: 42 µs is ~1% of a ~4.6 ms request, not ~40%. Where the same reasoning *does*
hold is the worker, and that is the whole of hazard 46/47: there the pipe read was
15 ms against a ~1 ms request, because a worker's read *is* the request, whereas a
FastCGI exchange is a rounding error on one. It cannot show up as throughput here,
and it does not.

Two things were checked rather than assumed:

- **No ini confound.** `php-cgi` and the `php` CLI read the same `php.ini` with identical
  values on this host (`opcache.enable=1`, `opcache.enable_cli=1`, `memory_limit=128M`,
  xdebug off), so unlike the Linux harness — which needs its `php-cgi-bench` wrapper
  because `php-cgi` reads `opcache.enable_cli` and `php-fpm` does not — no wrapper was
  used. `opcache.jit=tracing` is set but `opcache.jit_buffer_size=0`, so no JIT runs on
  any arm.
- **Idle FCGI pools cost nothing.** 24 parked `php-cgi` processes consumed **exactly 0
  CPU** over a 5 s idle sample, so leaving them up does not pollute another arm.

**One method note, because it bit.** A block-ordered run of the same two arms reported the
named pipe **22% faster** at c=1 (5.29 ms against 4.34 ms) and 22% *slower* at c=32 (15.98
against 18.18). Alternating them round by round gives the opposite of the first and no
support for the second — pipe 4.50–4.76 ms against TCP 4.59–4.68 ms, the same to 1.5%. **A
22% effect that reverses sign between two runs of the same arms is drift**, and on a host
with 20–30% background load a block layout manufactures exactly that. Compare by cycling,
not by blocks.

## What the loopback socket does under load

The 0.72 ms figure above is a *sequential* measurement. The question a Windows
deployment actually faces is what the socket does once the pool is saturated, and
because the pipe arm is capped by something the socket arm is not, the answer is not
the same ratio. Measured on this host (Ryzen 5 7500F, 6 cores / 12 threads, PHP
8.3.31 ZTS, stokehold `279dc35`), `GET /items`, 12 workers, 5 runs of 5 s per cell:

| conc | socket rps | pipe rps | ratio | socket p50 | pipe p50 |
|---|---|---|---|---|---|
| 1 | 1,418 | 66 | **21.5×** | 0.658 ms | 15.11 ms |
| 4 | 5,297 | 265 | **20.0×** | 0.683 ms | 15.10 ms |
| 8 | 8,651 | 528 | **16.4×** | 0.903 ms | 15.09 ms |
| 12 | 8,528 | 775 | **11.0×** | 1.215 ms | 15.53 ms |
| 16 | 8,796 | 775 | **11.3×** | 1.547 ms | 16.04 ms |
| 24 | 8,655 | 774 | **11.2×** | 2.082 ms | 31.03 ms |
| 32 | 8,599 | 773 | **11.1×** | 2.504 ms | 45.34 ms |

**The peak is ~8,800 rps against ~775 — a ceiling ratio of 11.3×, and 26× the Linux
pipe figure.** The interesting part is *why the ratio shrinks from 21× to 11×*, and it
is neither arm's fault:

- **The pipe arm cannot use more than one worker.** Up to concurrency 8 it scales
  linearly at **exactly 66 rps per connection** (66 / 132 / 264 / 528), and then stops
  dead. It saturates at **775 rps regardless of whether 12 or 32 connections are
  offered** — 12 workers × 66 rps, within 0.4% across every cell. The ceiling *is* the
  15 ms per read, and nothing the client does can move it. Beyond 12 connections the
  extra ones merely queue, which is why p50 rises to 31 ms and then 45 ms while
  throughput does not move at all.
- **The socket arm is worth ~1,390 rps per worker** (8,651 at 8 connections against the
  pipe's 528) and is capped at **~9,000 rps by CPU, not by the pool**: at c=12 it uses
  **61–63% of the whole host while the pipe arm uses 2.9–6.6%**, and *adding* concurrency
  past 12 buys nothing because every worker is already busy.

That the socket's 11× is a *CPU* ceiling rather than a limit of the loopback transport
was checked rather than assumed, because the load generator is home-grown: one client
at c=12 (9,306 rps) and two clients at c=6 each (9,209 total) land in the same place,
so the client is not scarce, and its own cost is **0.06 ms per request** (½ core at
8,200 rps). The server's 12 workers are the limit.

So under load the loopback socket is not merely the difference between a responsive
Windows deployment and an unusable one — it is the difference between **~775 rps and
~8,800 rps**, and it does it while *leaving* 38% of the host idle for PHP, where the
pipe arm sits blocked and consumes almost nothing.

Two honest caveats. Comparing 8.6k against the Linux `wrk` figure of ~19.4k mixes load
generators and hosts, so it is indicative and not evidence; the like-for-like
comparison is the sequential one, where socket 0.82 ms against Linux 0.556 ms is the
same order and pipe 15.26 ms against Linux 0.556 ms is not. And the raw rows are
committed as `results/raw-windows-279dc35.tsv` — the 70 rows behind this table, five
repeats per cell and **zero errors in any of them**, in the repository's own raw
format, so every figure above is the median of five committed rows rather than a
number taken on trust. The two transports carry separate arm keys (`P` = socket,
`Pp` = pipe) on purpose: `scripts/compare_runs.py` keys a cell on `(arm, conc,
endpoint)`, so giving both rows `P` would have merged the two transports into one
median and destroyed the comparison. `compare_runs.py` loads the file and reports the
`P` cells; the `Pp` rows are in the same file for the same treatment.

## Reproducing

```bash
composer install
php seed.php
bash scripts/bench.sh
```

`composer install`, not `composer update`, and `composer.lock` is **tracked** here. That is
deliberate, and it is the opposite of a library's convention: the lock is an input to the
measurement. Eleven dependencies are floating ranges — including `spiral/roadrunner`, which *is*
the RoadRunner arm — so an unlocked `composer install` a month from now would benchmark a
different RoadRunner against the same stokehold and quietly produce an incomparable number. The
lock fixes every one of them; the three `sailantis/*` packages are pinned by commit ref in
`composer.json` itself. If a run ever needs a newer RoadRunner, move the lock on purpose and say
so in the results, rather than letting `composer update` do it silently.

`composer validate --check-lock` reports the lock as current with the committed `composer.json`,
and its `content-hash` was regenerated with the same no-flags `json_encode` Composer itself uses.

`bench.sh` needs `wrk`, `php-cgi`, and — for the FPM arm — `nginx`, `php-fpm` and
passwordless `sudo` (it writes one pool file and one vhost, both named
`bench-stokehold`, and removes them afterwards). Missing pieces skip their arms
with a reason rather than failing the run.

Useful knobs:

```bash
ARMS=P,T,U      bash scripts/bench.sh    # a subset
CONC=1,4,8,16,32 REPEAT=3 bash scripts/bench.sh
ENDPOINTS=/items  bash scripts/bench.sh  # the ORM page only
SKIP_FPM=1       bash scripts/bench.sh
CROSSOVER=1 CROSS_CONC=1,4,8,16 bash scripts/bench.sh
```

## Four measurements, four questions

The repository runs four passes, and reading the wrong one is the mistake this
project made for several weeks:

| pass | holds concurrency at | answers |
|---|---|---|
| `wrk` sweep | the slot count (12) | how many requests per second can this host push |
| `latency.php` | 1 | what does one request cost, with nothing to overlap it |
| `crossover.php` | a range, 1..16 | at what load does the model advantage disappear |
| `diag-split.sh` | 32 | whose CPU is a request spending — the server's or PHP's |

They disagree, and the first two are both right. A 12-slot sweep overlaps every
request's framework boot with eleven other requests, so the boot vanishes from the
aggregate rate; a single request gets no such help. The same pair of servers reads
as **2.15x** and **2.02x** depending on which pass is asked. The crossover pass
measures the middle and finds the advantage flat at ~2.0x from concurrency 1 to 16
— it does not cross over within the range this host can generate load for.

The fourth pass exists because the third one left a discrepancy it could not
explain: stokehold's warm arm sat ~10% behind RoadRunner's on *every* endpoint,
while running the same application through the same model. Wall clock cannot
localise that — both servers report the same latency and the same rps — but CPU
can, because the total is the sum of two halves. `diag-split.sh` attributes CPU
per request across the arm's process tree (walked up the PPID chain, not matched on
process name) and showed the whole gap was in stokehold's own server process:
413 µs against 309 µs, with the two totals agreeing to 1%. `diag-profile.sh` then
named three functions, each of which made a full pass over the response body per
request, and fixing them took the front-end from 413 µs to 137 µs — now cheaper
than RoadRunner's 153 µs, and enough to put stokehold ahead end to end.

The third pass exists because of a harness bug worth recording: the first version
drove N handles from one process with `curl_multi` and reported concurrency 2 as
*exactly* 2x the latency of concurrency 1, on three unrelated servers. That is the
client, not the servers — `curl_multi_select($multi, 0.05)` takes seconds, so its
retry floor was 50 ms. The current version runs N processes, each using the same
blocking loop `latency.php` uses, and agrees with it to 0.1% at concurrency 1.

**The lesson from the fourth pass, which the other three could not teach:** two
numbers agreeing to 10% is not evidence that either is right. It took attributing
CPU, rather than measuring wall time more carefully, to find a 3x cost difference
hidden inside a 10% throughput difference.

## What the harness refuses to do

The earlier experiments in this project produced numbers that were wrong in ways
that looked like findings. Every one of them is now a guard in `bench.sh`:

- **No arm is measured until a real request succeeds.** Each arm must return HTTP
  200 *and* a page containing rendered rows. A server that starts and answers 500
  would otherwise publish a plausible throughput figure for an arm that never ran
  the application. A cell that cannot be measured is recorded as `FAIL`, never as
  a zero.
- **Every arm runs the same PHP.** php-cgi is wrapped because `opcache.enable_cli`
  is read by php-cgi and ignored by php-fpm, and the two warm arms are wrapped too
  because a bare `php worker.php` is exposed to whatever the host's CLI happens to
  have installed. That is not hypothetical: removing xdebug from this host's CLI
  package roughly **doubled** the two warm arms (P 8,566 -> 16,322 rps, R 8,727 ->
  18,265) while F, T and U did not move at all — the hazard-28 pattern, a
  difference of ini mistaken for a difference of server, on the one pair nobody
  had wrapped.
- **A freshly modified checkout is waited out.** `opcache.file_update_protection`
  defaults to 2 seconds, and opcache refuses to cache a file whose mtime is newer.
  A script written seconds before measuring misses on every request *by design*,
  which looks exactly like an opcache that does not survive between requests. This
  project has already drawn that wrong conclusion once.
- **RoadRunner is stopped by config path, not binary path.** Its argv is
  `./rr serve`, so a `pkill` on the resolved binary matches nothing and the worker
  survives into the next run holding its port.
- **Leftovers are reported.** A run that leaks a php-cgi pool corrupts the next
  one; one earlier host accumulated 68 orphans, each holding a port and competing
  for the cores under test.
- **`max_requests = 0` means never recycle.** It is written explicitly in the
  configurations because it is what a real php-fpm pool carries — and because
  reading it as "recycle after every request" is a mistake this project has
  already made, which silently boots the framework per request and turns the warm
  arm cold.

## Why the application is azera

The application is copied from `azera-competition` unchanged, and that is
deliberate: the published figures there (RoadRunner 0.255 ms warm vs nginx +
php-fpm 0.785 ms cold on `GET /`) are the reference this repository's numbers are
read against. Changing the app would make the two datasets incomparable for no
gain.

Its dependencies are pinned to exact commits rather than to a branch, so a run six
months from now measures the same framework:

| package | commit | why not the tag |
|---|---|---|
| `sailantis/azera-framework` | `4292198` | the worker path needs `Request::setRawBody()`, which postdates `v0.1.0` |
| `sailantis/clarity-engine` | `ee06010` | the released `v0.3.0` plus one documentation commit |
| `sailantis/stokehold-worker` | `5ede306` | current `main`; the SDK has no tag yet |

All three are public, and `"no-api": true` on each repository makes composer clone
them over git instead of through the GitHub API, which needs no token.

## Layout

```
BenchApp.php            the application: bootstrap once, dispatch, cleanup
public/index.php        the COLD entry point (F, T, U)
worker.php              the WARM entry point (P)
roadrunner-worker.php   the WARM entry point (R)
seed.php                creates data/bench.sqlite
apps/azera/             the application, copied from azera-competition
conf/                   one stamped config per arm
scripts/bench.sh        the harness
scripts/diag-split.sh   CPU per request: server process vs PHP workers
scripts/diag-profile.sh perf record on the server process, flat symbol report
results/                published numbers
```

`public/index.php` and `worker.php` are separate files on purpose. A cold arm has
to pay the framework boot *inside the timed request*, and the only honest way to
show that is for the entry script to boot. Sharing the worker's loop would quietly
make the cold arms warm and erase the effect being measured.

## Reading the results

`scripts/bench.sh` writes `results.tsv` (every repeat) and prints a summary of
medians. Ratios are the point, not absolute figures: absolute throughput depends
on the host, while the warm-over-cold ratio is a property of how much the
application boots — which is exactly the thing the earlier trivial-handler
measurements could not see.

That is also why a superseded sweep is kept rather than overwritten. `results/raw.tsv`
is the current run, `results/raw-841c963.tsv` the one before it, and
`scripts/compare_runs.py` prints both tables and the ratio change between them:

```bash
python3 scripts/compare_runs.py results/raw-841c963.tsv results/raw.tsv
```

Read the ratios, not the throughput. A 1.5% median change across the cells is
consistent with noise — RoadRunner moved by 2.8% in the last re-run without a
single line of its code changing, which is the honest indicator of how much of
any such difference is real. A *ratio* that moves further than the spread is the
thing worth explaining.

**When a ratio surprises you, measure whose CPU it is before theorising.** The
`diag-*` scripts are here because that is how the largest single finding in this
repository was made: a 10% throughput gap between two servers was a 3x difference
in *server* CPU per request, invisible in wall clock, and fixing it moved the
result by more than any configuration change in the history of the harness.
