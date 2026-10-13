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

The design memory behind stokehold itself — the numbered hazards, the step list and
the open decisions — is [`stokehold/docs/plan.md`](https://github.com/sailantis/stokehold/blob/main/docs/plan.md).
Where this README says "hazard 46" it means entry 46 there, and its section 10
("Where the work stands") is the current state of the build.

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
the Linux arms show (8,179 against 18,655, or 2.3×). Windows is slower for both
deployment models; it is the cold one that pays much more of the penalty:

| metric (`GET /items`) | Linux, 12 cores, idle | Windows, 6c/12t, 20–30% busy | ratio |
|---|---|---|---|
| resident worker, sequential p50 | 0.585 ms | 0.82 ms | 1.4× |
| FastCGI, sequential p50 | 1.52 ms | 4.6 ms | **3.0×** |
| peak throughput, resident worker | 18,655 rps | 9,717 rps | 0.52× |
| peak throughput, FastCGI | 8,179 rps | 1,728 rps | **0.21×** |

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

Two honest caveats. Comparing 8.6k against the Linux `wrk` figure of ~18.7k mixes load
generators and hosts, so it is indicative and not evidence; the like-for-like
comparison is the sequential one, where socket 0.82 ms against Linux 0.585 ms is the
same order and pipe 15.26 ms against Linux 0.585 ms is not. And the raw rows are
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
| `diag-split.sh` / `diag-checksum.sh` | 32 | whose CPU is a request spending — the server's or PHP's |
| `diag-slots.sh` | 32, with the thread count varied | is the tail the pool's queueing or the load generator's |
| `diag-slots.sh` (A/B mode) | 24 and 32, every variant inside one round | did the pool fix really buy what a blocked run said |

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

That last claim is the one worth re-checking, and a **fifth pass exists to check it**.
A blocked sweep measures one arm at a time, so a host that drifts over twenty minutes
charges that drift to whichever arm ran last. `ab-perf.sh` measures every variant
inside the same round with the starting order rotated, so the estimator is a
within-round ratio and the spread across rounds is the error bar. It re-ran the
question that started this section — see "Is the lead still there?" below.

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

The fifth pass exists because the fourth one localises a cost to a *process* and the
question that followed was about a *mechanism*. The tail in "The one cell RoadRunner
wins" could have been the pool's queueing or the load generator's own thread
scheduling — both live in a process, both cost CPU, and `diag-split.sh` cannot tell
them apart because it attributes CPU rather than time waited. `diag-slots.sh` holds
concurrency fixed and varies only `wrk`'s thread count, which changes nothing on the
server side, and reads the pool's own wait histogram from the server's shutdown line.
The pool's answer settled it: the tail is the pool's, and the client is innocent.

## Is the lead still there? — yes, and it is one function

This was asked because five committed sweeps compared against each other say the
answer might be no: the lead read 1.20x in one sweep and 1.09x in the next one, which
ran **identical warm code**, and the sweep after that read ~3% below its predecessor in
every cell. Comparing sweeps cannot settle it — in the sweep that looked like a
regression, *every* arm fell, including RoadRunner and nginx + php-fpm, which none of
the intervening commits touch. That is the host, not stokehold.

So four variants were measured **inside the same round**, with the starting order
rotated by round, on an idle host: the current build; the current build with the
per-frame checksum switched off; the current build with **only** `crc32c` reverted to
the hand-written bit-by-bit loop it replaced; and RoadRunner as a control that shares
no code with any of them. Seven rounds × 2 endpoints × 3 concurrencies = **168
measured cells, none failed**.

| ratio, median over 7 rounds | `/` c=8 | `/` c=16 | `/` c=32 | `/items` c=8 | `/items` c=16 | `/items` c=32 |
|---|---|---|---|---|---|---|
| **`crc32c` fix** (current / reverted) | **+11.8%** | **+11.4%** | **+16.3%** | **+10.2%** | **+12.1%** | **+13.7%** |
| checksum switched off | +2.0% | +2.9% | +2.5% | +3.0% | +2.7% | +2.8% |
| current build vs RoadRunner | +18.0% | +4.6% | +4.2% | +3.3% | **−1.7%** | +7.0% |
| **reverted build vs RoadRunner** | **+5.3%** | **−6.5%** | **−9.1%** | **−5.8%** | **−12.9%** | **−6.2%** |

The first row is positive in **all 42 paired cells**; the last row is negative in all six
cells of every round. So the effect is not merely still there — **it is the whole lead**.
Without the fix the build is behind RoadRunner everywhere, by 5.8–12.9%. With it, it is
ahead almost everywhere.

The revert is targeted rather than an old checkout, and that is what makes the number mean
something: building the commit *before* the fix would have bundled the FastCGI parser
de-allocation and the single-pass response parser along with it, isolating nothing. Only
`header::crc32c` was restored, both binaries return **byte-identical** bodies for both
endpoints, and the test that pins the checksum to its standard check value still passes on
the reverted tree.

**Which side pays is the part worth naming**, because it is where the earlier estimate went
wrong. `crc32c` is hashed **twice** per response: once by the PHP worker writing the frame,
once by the server reading it. Measured per request on `/items`:

| build | c | server µs | PHP µs | total µs |
|---|---|---|---|---|
| reverted (bit-by-bit) | 32 | **184** | 287 | 471 |
| current (hardware CRC32) | 32 | **125** | 283 | 408 |
| current, checksum off | 32 | **121** | 281 | 402 |

The fix removes **59 µs of server CPU per request (−32%)** and leaves the PHP column alone,
because the worker's hash was already hardware-accelerated. The earlier estimate that called
the checksum knob "0.26%" timed only the Rust-side encoding and therefore priced half of it;
measured end to end the knob is worth ~6 µs per request (~1.5%). Its throughput median is
positive but its seven-round spread crosses 1.00 in four of six cells, so read it as a small,
real, now-measured saving — and note the reason it stays on: the checksum's value is integrity,
and 3% is not a reason to turn off a corruption check.

Raw rows are committed — `results/ab-perf.tsv` and `results/cpu-per-request.tsv` — and both
passes reproduce with `scripts/ab-perf.sh` and `scripts/diag-checksum.sh`.

### The one cell RoadRunner wins is not a crossover, but the tail is real

The table above has a single cell where RoadRunner is ahead — `/items` at c=16, −1.7% — and the
tempting reading is slot exhaustion, because stokehold's pool has 12 slots and 16 is the first
concurrency above it. A denser sweep says no: at c=12, 14, 16, 18, 20, 24 the lead is **+1.3%,
+1.1%, −1.1%, −1.3%, −0.4%, +3.0%**, with the per-round spread crossing 1.00 at four of the six
levels. There is no threshold and no bend; there is a ~1% deficit sitting somewhere between
c=16 and c=20, which is about 200 rps out of 18,000. Per-request CPU confirms it — stokehold's
server cost per request is **flat at 121–126 µs from c=8 to c=32**, so nothing changes at 16 for
it to cross over at.

What the denser sweep *did* find is a tail that diverges while the median does not:

| concurrency | stokehold p99 | RoadRunner p99 |
|---|---|---|
| c=12 | 1,640 µs | 1,760 µs |
| c=16 | 3,470 µs | 2,105 µs |
| c=20 | 6,770 µs | 2,415 µs |
| c=24 | 10,425 µs | 2,690 µs |

RoadRunner's tail is flat above its slot count — what a pool with a queue looks like.
Stokehold's grows with offered load while its **p50 stays better** than RoadRunner's at every
level. Growing p99 with an improving median is queueing, not slowness: the requests are not
served slower, they wait longer before being served.

The suspected cause was in `pick_slot`: it advances a cursor and then takes each candidate
slot's mutex until one reports available, where "available" means the worker is *healthy*, not
that the slot is *free* — and the mutex is then held across the whole request.

**That was a hypothesis. It has since been measured, and it holds.** The pool now times every
request from asking for a slot to holding one, per slot, and counts those waits into a
powers-of-two histogram so it can report its own p50 and p99; the server prints both at shutdown
(stokehold `4dd402a`, `a6df392`). Because the figure is produced inside the server it cannot
contain anything the load generator did, which is what makes it evidence rather than a second
correlation.

First, the load generator was ruled out. This harness drives `wrk` as `-t$c -c$c`, so at c=32 the
client owns 32 threads on a 12-core box, and that was the other candidate for the tail. Holding
concurrency at 32 and varying only the thread count changes nothing on the server side:

| client threads | client p99 | pool mean wait | pool p99 wait |
|---|---|---|---|
| 2 | 17.80 ms | 895 µs | 16.4 ms |
| 32 | 18.33 ms | 898 µs | 16.4 ms |

Then, with concurrency equal to the thread count (`scripts/diag-slots.sh`):

| concurrency | excess over 12 workers | client p50 | client p99 | pool mean | pool p50 | pool p99 | client `p99−p50` | pool `p99−p50` |
|---|---|---|---|---|---|---|---|---|
| 12 | 0 | 0.71 ms | 1.68 ms | 34 µs | 2 µs | 1.02 ms | 0.97 ms | 1.02 ms |
| 16 | 4 | 0.79 ms | 3.94 ms | 157 µs | 3 µs | 2.05 ms | 3.15 ms | 2.05 ms |
| 20 | 8 | 0.88 ms | 7.68 ms | 325 µs | 4 µs | 8.19 ms | 6.80 ms | 8.19 ms |
| 24 | 12 | 0.97 ms | 10.74 ms | 509 µs | 4 µs | 8.19 ms | 9.77 ms | 8.19 ms |
| 32 | 20 | 1.16 ms | 18.98 ms | 906 µs | 19 µs | 16.4 ms | 17.82 ms | 16.37 ms |

The wait **grows from concurrency 13 rather than stepping** — a step would mean waiting for the
one request already in front of you, and 34 → 157 → 325 → 509 → 906 µs across 0 → 4 → 8 → 12 → 20
excess clients is a queue accumulating instead. It is **unfairness, not slowness**: the pool's
median wait is 2−19 µs while its p99 is 1−16 ms, most requests take an uncontended mutex and a
few wait for whole requests, and the pool's `p99 − p50` tracks the client's at every level. And
the mean is a real cost besides: at c=32 a request spends **0.91 ms of its 1.69 ms** waiting for a
busy worker.

It is still recorded as a deployment property rather than a throughput one — nothing in the
tables above moves, and throughput at c=24 is already 4% ahead. What is no longer open is whether
the tail is real or whose it is. What *is* still open is which fix: `try_lock` in the scan, or a
real fair queue. Both are consistent with this data and neither has been built or compared.

**Built: the fair queue, and it holds.** `pick_slot`, the cursor and the healthy-not-free test are
gone, replaced by a lease taken from a free list — a slot cannot be leased twice, so a request now
waits for the slot it will actually use rather than for whichever worker the cursor happened to
point at. Same sweeps, same host:

| concurrency | rps | client p50 | client p99 | pool mean wait |
|---|---|---|---|---|
| 12 | 15,686 → 16,342 (+4%) | 0.71 → 0.69 ms | 1.68 → 1.41 ms | 34 → 0 µs |
| 20 | 18,581 → 22,114 (+19%) | 0.88 → 0.85 ms | 7.68 → 1.78 ms | 325 → 123 µs |
| 32 | 18,982 → 22,360 (+18%) | 1.16 → 1.35 ms | 18.98 → 3.68 ms | 906 → 625 µs |

Three notes, because two of these were not the point. **Nothing was shed**: `wrk` prints non-2xx
responses as its own line and printed none, so the gain is real service rather than `503`s. The
**throughput rise of 13–21% was not predicted** — the old scan locked and `try_wait`-ed each
candidate per request, which is CPU on 12 cores at 19,000 rps — and an unpredicted win is worth
re-measuring rather than celebrating. And the **median at c=32 is 16% worse**, which is the trade
that was approved: the request that would have been served on contact now shares the queue. At c=12
it is slightly better, so the cost is confined to the range where there is something to share.

**Re-measured interleaved, because that unpredicted win is exactly the kind of number this
repository has learned not to trust.** A blocked before/after charges host drift to whichever build
ran last — the trap that once produced a 22% "effect" that reversed sign when the two binaries were
interleaved instead (hazard 49). So both builds were measured again inside the same round in rotating
order, with RoadRunner as a control that shares no code with either: `diag-slots.sh` gained an A/B
mode and `scripts/slots-report.py` reads it. 7 rounds × 3 variants × 2 concurrency levels = 42
measured cells, 0 discarded, after a discarded warm-up pass per round:

| concurrency | new / pre-fair | spread over 7 rounds | new / RoadRunner | pre-fair / RoadRunner |
|---|---|---|---|---|
| c=24 | **1.245× (+24.5%)** | 1.223–1.271 | 1.272× | 1.030× |
| c=32 | **1.229× (+22.9%)** | 1.197–1.244 | 1.302× | 1.057× |

The spread never crosses 1.00 and all 14 paired comparisons point the same way. The control is what
makes it legible: the **pre-fair binary still measures +3.0%/+5.7% over RoadRunner**, the same band
hazard 51's interleaved A/B established for it, while the current build sits at +27%/+30%. So the
blocked layout *understated* the gain, and this is the largest throughput effect this project's own
code has produced — larger than the `crc32c` fix's +10–16%, which was called *"the whole lead"* over
RoadRunner. The two effects larger than it are not stokehold's: removing xdebug from the host's CLI
PHP doubled the warm arms, and that was a configuration bug. The pool's p99 halves twice over as well (10.92 → 2.19 ms at c=24, 17.44 → 3.47 ms at
c=32) *while* the mean wait falls (522 → 263 µs), and the p50 rises from 8 µs to 256 µs — the fairness
made visible, the request served on contact now waiting a little so the unlucky one does not wait
10 ms. `run_measurement` now fails loudly on any `Non-2xx` line, so a future run cannot quietly trade
throughput for `503`s.

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
- **Leftovers are caught *per arm*, and the pattern had to be fixed to see them.**
  A run that leaks a php-cgi pool corrupts the next one; one earlier host
  accumulated 68 orphans, each holding a port and competing for the cores under
  test. Every arm is now checked immediately after `stop_arm` and the run refuses
  to continue if a leak cannot be cleared, so a leak can never cross into an arm
  that is measured.
  The check had been worse than useless as written: it matched the literal string
  `php-cgi -b`, but arms T and U spawn PHP through the `php-cgi-bench` wrapper, whose
  argv inserts its `-d` flags *before* `-b` —
  `/usr/bin/php-cgi -d opcache.enable_cli=1 … -b 127.0.0.1:19300` — so the pattern
  matched **0** of the 12 children a running arm actually had. Measured on the bench
  host: `pgrep -f 'php-cgi -b'` returned 0 while twelve children were alive, and it
  still returned 0 after a `kill -9` of the server left all twelve orphaned. The
  reported "8 strays" were therefore leftovers from older configs that invoked
  `/usr/bin/php-cgi` directly, and the guard would have reported clean through any
  leak the arms under measurement produced. It now matches `-b` as its own word via
  `ps -eww` (the `-ww` is load-bearing: without it a long wrapper command line is
  truncated and loses the flag), which never matches php-fpm's `php-fpm: pool www`
  children — so a host serving its own sites is neither counted nor reaped.
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
scripts/diag-slots.sh   the pool's own slot-wait histogram vs the client's p99
                        (VARIANTS=a,b,rr adds a rotated interleaved A/B of two builds)
scripts/slots-report.py reads an interleaved diag-slots.sh run: within-round ratios
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
is the current run (`91cc7b6`), and the ones before it are kept beside it —
`raw-ddaada7.tsv` and `raw-841c963.tsv` — so
`scripts/compare_runs.py` prints both tables and the ratio change between them:

```bash
python3 scripts/compare_runs.py results/raw-ddaada7.tsv results/raw.tsv
```

Read the ratios, not the throughput. **The absolute rps column is not comparable between
sweeps, and the last two revisions are the proof:** `ddaada7` read 1–3% below `841c963` in
every cell, and the only code change between them was four micro-optimizations whose own
measurements claimed no throughput at all. Re-deriving it from the two committed files
shows what was actually there — every arm fell *except* the one the commits touched
(P +0.35%, R −2.79%, F −1.63%, T −1.54%, U −1.77%, RoadRunner slower in 10 of 10 cells).
The way to read that is a ratio against a control arm, which cancels whatever the host did
underneath both, and by that reading the four commits *improved* stokehold's lead by 5.3%
on `/`. A *ratio* that moves further than the spread is the thing worth explaining; a
throughput delta of the same size is not.

**When a ratio surprises you, measure whose CPU it is before theorising.** The
`diag-*` scripts are here because that is how the largest single finding in this
repository was made: a 10% throughput gap between two servers was a 3x difference
in *server* CPU per request, invisible in wall clock, and fixing it moved the
result by more than any configuration change in the history of the harness.
