# Five ways to serve one page — 12 cores, one host

**Host:** Xeon Gold 5412U, 12 cores, 3884 MB, Ubuntu, PHP 8.3.35 NTS, nginx 1.24.0,
RoadRunner 2025.1.15, stokehold `91cc7b6`, wrk 4.1.0.
**Method:** `scripts/bench.sh`, 5 s per cell, 3 repeats, median reported, 12 workers/slots
in every arm, endpoints `GET /` and `GET /items`, no failed cells. Plus three extra passes:
`scripts/latency.php` (the sequential per-request methodology the published figures used),
`scripts/crossover.php` (the same latency at concurrency 1..16), and `scripts/diag-split.sh`
(CPU per request, attributed across the arm's process tree).

> **This revision (stokehold `91cc7b6`) re-measures all five arms on the current `main`.**
> The previous tables were taken at `ddaada7`, whose four code commits were the FastCGI
> response-assembly fix, the worker request path, the reply-frame buffer, and the optional
> checksum. Five commits have landed since — the Windows/loopback transport work and a pure
> refactor that split `worker_pool.rs` into six files along its real seams.
>
> **The honest reading of the previous sweep was wrong, and correcting it is why this
> revision exists.** That sweep read 1–3% slower than the one before it in every cell, and
> the note here dismissed it as drift using a re-run of R and F that was never committed —
> a sentence, not data. Re-deriving it from the two committed files shows the pattern the
> note missed: every arm fell *except* the two arms the four commits touched (P +0.35%,
> R −2.79%, F −1.63%, T −1.54%, U −1.77% — RoadRunner slower in 10 of 10 cells). The
> absolute rps column is not comparable between sweeps; the ratios are, and by those the
> four commits *improved* stokehold's lead (P/R +5.3% on `/`).
>
> **And the leak guard that sweep relied on could not see the arms it guarded.** It matched
> the literal string `php-cgi -b`, but arms T and U spawn PHP through a wrapper whose argv
> puts its `-d` flags before `-b`, so the pattern matched **0** of the 12 children a running
> arm had. It reported 0 while twelve were alive and still reported 0 after a `kill -9` left
> all twelve orphaned. The "8 strays" it did report were leftovers from older configs, not
> from the arms being measured. The guard now matches `-b` as its own word and runs after
> **every** arm, refusing to continue if a leak cannot be cleared; this run reports
> `leak check [P|T|U|R|F]: clean` and 0 strays at teardown.
>
> **The refactor cannot cost throughput, and that was measured rather than argued.** P is
> ~3.3% below the previous sweep here, above every control arm's drift, and the only code
> change since is the file split. Two binaries — `ddaada7` and `91cc7b6` — were built and
> alternated `A,B,B,A` on the same idle host, 5 s × 3 repeats per cell:
>
> | endpoint | c=1 | c=4 | c=8 | c=16 | c=32 |
> |---|---|---|---|---|---|
> | `/`, `91cc7b6` vs `ddaada7` | −0.52% | +0.92% | +0.68% | +0.23% | −0.42% |
> | `/items`, same | +1.00% | +1.68% | −0.24% | −1.04% | −1.56% |
>
> Median **−0.00%**, 5 of 10 cells each way, every delta inside the 3.3% within-cell repeat
> spread. So the refactor is free, and the ~3.3% on P in the table below is drift that
> happened to land on this run rather than on stokehold.
>
> The per-arm medians below come from the comparison, not from this note: **P −3.3%**,
> **R −1.5%**, **F −0.9%**, **T −0.6%**, **U −2.0%**. Read the ratios, not the deltas.
> `results/raw-ddaada7.tsv` is kept alongside `results/raw.tsv`, so the comparison can be
> re-derived with `scripts/compare_runs.py` rather than believed.
>
> One ratio move is worth naming so it is not read as an effect: **P/F at c=1 on `/` reads
> 1.79× here against 2.11× before (−14.7%)**, and it is one noisy cell — P's three repeats in
> this run were 3,083 / 3,308 / 3,268, a 7% spread, and at c=1 the `wrk` client shares the
> host with the server it is measuring. Every other P/F cell on `/` is between 1.87× and
> 2.00×, both here and at `ddaada7`.

> **The previous revision (stokehold `841c963`) refreshed the five measured tables after the
> transport-buffering pass** — every read and write path in stokehold's three transports now
> enters the kernel once per frame instead of once per frame *field*. It changes throughput by
> a few percent, not by a factor; the A/B against the previous build is at the foot of the
> transport section. The two CPU-attribution tables ("Where the warm arm's 10% went", "The
> cold model's real cost is CPU") are carried over from the previous build and were not
> re-measured; their conclusions — a duty cycle, not headroom — do not depend on the few
> percent that moved.

> **There are three passes and they answer three different questions.** A wrk sweep holds
> concurrency at the slot count and reports what the host can push; `latency.php` holds it
> at 1 and reports what one request costs; `crossover.php` sweeps it and reports where the
> model advantage sits at each load. This report has been wrong in *both* directions by
> reading one pass as another — first claiming the warm model was worth nothing in
> throughput (it was a config bug on the unwrapped arms), then reading a throughput ratio
> against a published latency ratio. The three passes now agree with each other, and the
> agreement is the result, not any single table.
>
> **A fourth pass was added after the first three disagreed with themselves.** A 10%
> deficit against RoadRunner on *every* endpoint, in two implementations of the same
> design, is small enough to be a property of stokehold's code rather than of the model —
> and it was. CPU attribution found it in an hour, where wall clock had not found it in
> three passes; see "Where the warm arm's 10% went". Every number in this report below is
> from the fixed build.

## The two endpoints are different experiments

- **`GET /`** returns 5 KB and does almost no work: the container is built, the route
  matches, a tiny template renders. It measures **the server and the deployment model**.
- **`GET /items`** returns ~12 KB, runs one ORM query and renders 20 rows. It measures
  **the server, the model, and a response large enough to be divided across transport
  segments**.

## Corrected summary

| question | answer | how measured |
|---|---|---|
| Does the warm model pay off? | **yes, ~2.1x per request** (published: 3.3x) | sequential latency |
| Does it show in aggregate throughput? | **yes on `/`, ~2.0x; and 2.24x on `/items` at c=32** (originally ~1.0x, which was a bug) | wrk, 12 slots |
| At what load does it stop paying? | **it does not, within 1..16** - flat ~2.0x | crossover |
| Why does the cold model idle 16% of the cores? | **it costs 1,063 us of CPU per request against 666** - a duty cycle, not headroom | CPU accounting |
| Is loopback TCP a problem? | **no - T and U agree to 3%** (a 40 ms/request stall in stokehold's client was) | latency + wire |
| Which transport should I use? | **either** - keep `unix:` for permissions, not speed | both |
| Does stokehold agree with RoadRunner? | **it leads by 1-5% at c=32**, warm vs warm, with a cheaper front-end (136 us vs 155) | both |
| What was the syscall-buffering pass worth? | **2-6% on `/`, nothing on `/items`** - a fixed cost removed, not a proportional one | A/B, two binaries |
| Did the `worker_pool.rs` split cost anything? | **no - −0.00% median**, every cell inside the repeat spread | A/B, `A,B,B,A`, two binaries |

Everything below is the detail behind that table.

## `GET /` — the server and the model

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 3,268 | 12,969 | 23,277 | 34,393 | 36,008 |
| **R** | RoadRunner | warm worker, pipe | 2,998 | 11,143 | 19,729 | 33,462 | 35,512 |
| **F** | nginx + php-fpm | cold, unix socket | 1,822 | 6,503 | 11,638 | 18,365 | 17,960 |
| **U** | stokehold | cold, unix socket | 1,570 | 5,631 | 9,419 | 14,396 | 16,125 |
| **T** | stokehold | cold, loopback TCP | 1,533 | 5,865 | 9,736 | 14,212 | 16,743 |

Ratios at c=32: **P/F 2.00×**, **R/F 1.98×**, **T/U 1.04×**.

Two things follow. The piped warm worker (P) and RoadRunner (R) agree to within ~5% at
c=32 (36,008 against 35,512, **1.01×**), which is what makes the warm half of the
comparison credible — two independent servers, one model — and stokehold is the marginally
faster of the two at every concurrency up to 16. And on this endpoint **transport is
irrelevant**: 1.04× T/U, and T and U are themselves within 4%. The piped worker's advantage
comes from not booting the framework, not from the pipe.

## `GET /items` — throughput

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 1,789 | 6,892 | 11,522 | 16,696 | 18,655 |
| **R** | RoadRunner | warm worker, pipe | 1,726 | 6,535 | 10,956 | 17,189 | 17,804 |
| **F** | nginx + php-fpm | cold, unix socket | 808 | 3,049 | 5,429 | 8,412 | 8,325 |
| **U** | stokehold | cold, unix socket | 653 | 2,696 | 4,616 | 7,240 | 8,179 |
| **T** | stokehold | cold, loopback TCP | 650 | 2,838 | 4,736 | 7,014 | 8,014 |

Ratios at c=32: **P/F 2.24×**, **R/F 2.14×**, **T/U 0.98×**.

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
| **P** stokehold worker (warm) | 0.356 | **0.585** | 1.00× |
| **R** RoadRunner (warm) | 0.386 | **0.633** | 1.00× |
| **F** nginx + php-fpm (cold) | 0.592 | 1.242 | 1.66× / **2.12×** |
| **U** stokehold cold, unix (cold) | 0.701 | 1.521 | 1.97× / **2.60×** |
| **T** stokehold cold, TCP (cold) | 0.713 | 1.505 | 2.00× / **2.57×** |

Against `azera-competition`'s published `GET /items` for the same application
(RoadRunner 0.4647 ms, php-fpm 1.5318 ms = 3.30×) this run gives **2.12×**, and on `GET /`
(1.66× against a published 3.06×). So the effect is real, is in the published direction,
and reproduces about two-thirds of its magnitude on this host.

**T and U agree to about 2%** (0.701 vs 0.713; 1.521 vs 1.505), which is inside the 4–8%
run-to-run spread each arm shows across its ten runs. They did not agree at all before: T
was 1.656 ms against U's 1.466 ms because of a 40 ms-per-request stall in stokehold's own
client, not because of the transport. See "What this says about the transport" — that was
the single largest correction in this report's history, and it moved T by 34×.

> The warm arms read ~5–7% slower here than at `ddaada7` (P 0.332 → 0.356 ms, R 0.367 →
> 0.386) while the cold arms barely moved (F +2%, U −1%, T +3%). Both warm arms moving
> together, including the one this repository does not build, is the signature of a run
> effect rather than of stokehold — and the `A,B,B,A` binary comparison above measures the
> only candidate code change at −0.00%. This pass is 1,000 sequential requests per arm, so
> it is the most exposed of the three to a host that is not perfectly quiet.

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

### Where the warm arm's 10% went

The previous version of this report ended the model section by noting that P sat ~10%
behind R on every endpoint (16,329 against 18,258 rps on `/items`) and offering that as
agreement between two implementations of the same design. 10% is close enough to be called
agreement, which is exactly why it was worth a second look: two servers doing the same
thing with the same PHP should cost the same, and a persistent 10% in one direction is a
signature of one server's code rather than of noise.

Wall clock cannot localise it. Both servers report the same latency and the same rps, and
the total is the sum of two halves — the server process and the PHP workers. `perf` answers
the question only if you already know which half to profile. **CPU attribution answers
which half**, and it can be done in a shell script:

```
scripts/diag-split.sh   # snapshots utime+stime per process in the arm's tree,
                        # walked up the PPID chain from the server's own pid
```

Attributing by PPID chain rather than by process name matters: `comm` is truncated to 15
characters, so `php worker.php` and `php-cgi -b ...` are both just `php-cgi`-length names,
and RoadRunner's binary is `rr`. The tree is the fact; the name is a guess.

At concurrency 32 on `/items`, before the fix:

| arm | rps | server CPU/req | PHP CPU/req | total |
|---|---|---|---|---|
| **P** stokehold | 16,017 | **413 µs** | 608 µs | 1,021 µs |
| **R** RoadRunner | 17,860 | **309 µs** | 704 µs | 1,013 µs |

The totals agree to **1%** while the two server halves differ by **1.34×**. The gap was
entirely stokehold's front-end — not the worker protocol, not the pipe, not PHP, not the
client. (The PHP columns differ too, but in the other direction and by less; PHP runs the
same application on both, so that half is noise between runs.)

`scripts/diag-profile.sh` then named three functions. A flat `perf record` on the server
process during a saturated run:

| symbol | self time |
|---|---|
| `stokehold_worker::codec::Channel::read_frame` (with `crc32c` inlined) | **14.8–19.0%** |
| `stokehold_fcgi::client::parse_response_headers` | 5.2% |
| `stokehold_fcgi::client::split_response_body` | 5.2% |

All three were a full pass over the response body, per request, in userspace:

- **`crc32c` was a bit-by-bit implementation.** Eight shift-and-mask rounds per byte,
  written out by hand so the PHP SDK could mirror it line for line — but the SDK does not
  need to mirror the *implementation*, only the *value*, and the standard check value was
  already pinned by test. A 12 KB page meant ~96,000 inner-loop iterations per request. It
  is now the `crc32c` crate, which uses the CPU's CRC32 instruction where it exists.
  *The lesson worth keeping: "keep it dependency-free so another language can transcribe
  it" is a sound argument about the encode path and a bad one about the verify path.*
- **`parse_response_headers` began with `String::from_utf8_lossy(stdout)`** — validating
  UTF-8 across the entire payload, body included, and copying it when invalid, to find a
  separator that a byte search finds for free. It was also a correctness bug: the body
  offset was computed on a `String` whose length differs from the slice's, so a non-UTF-8
  byte *in the body* could move the located header terminator.
- **`split_response_body` searched for the same separator a second time**, over a body the
  header parser had just been through, using `windows(4).position` — four bytes compared at
  every offset of 12 KB, twice.

And after, measured the same way on the same host:

| arm, conc 32, `/items` | rps | server CPU/req | vs RoadRunner |
|---|---|---|---|
| **P** stokehold | **18,946** | **137 µs** | 0.89× |
| **R** RoadRunner | 18,019 | 153 µs | 1.00× |

**stokehold's front-end is now cheaper than RoadRunner's as well as faster end to end.**
`perf` no longer lists any stokehold function above 1.3%.

Two things generalise beyond this fix:

- **"We are N% slower than X" is not a fact about a design.** It is a fact about a
  measurement that has not been decomposed. Attribute CPU before optimising, or the
  optimisation is a guess — this gap was first hypothesised to be transport cost (hazard 23)
  and was wrong, and three of the four items above would never have been visible in wall
  clock.
- **A response payload is scanned once per request, whatever the protocol**, and the two
  obvious places to scan it — the checksum and the header parse — are the two that get
  written by hand for clarity. Both wanted the boring version.

## What this says about the transport

**Loopback TCP and a unix socket are equivalent. T and U agree to within 4% in the sweep,
1.04× at c=32 on `/` and 0.98× on `/items`, and to within 2% in the sequential pass — and
there is no transport penalty to explain.**

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

### The buffering pass: what the syscall cut was worth in wall clock

Hazard 38 in `stokehold/docs/plan.md` replaced every unbuffered transport stream with a
buffered one, so a frame — a header followed by a payload — stops costing one `read(2)` per
field. The counted syscalls fell a long way: the worker's response read went **6 → 1**, the
FastCGI client's reply **4 → 1**, and the front-end's handling of a twelve-record request
**40 → 1**.

Those are syscall counts, not throughput, and the difference is worth measuring rather than
assuming. Two binaries — one from the commit before the pass, one from after — on the same
host, same harness, three repeats, medians:

| arm | endpoint | conc | before | after | |
|---|---|---|---|---|---|
| P worker (pipe) | `/` | 32 | 36,986 | **38,141** | +3.1% |
| P worker (pipe) | `/` | 8 | 23,800 | 24,320 | +2.2% |
| T spawn_cgi (TCP) | `/` | 32 | 15,901 | **16,868** | **+6.1%** |
| U spawn_cgi (unix) | `/` | 32 | 16,506 | 16,900 | +2.4% |
| T spawn_cgi (TCP) | `/items` | 32 | 8,006 | 8,009 | 0% |
| U spawn_cgi (unix) | `/items` | 32 | 8,353 | 8,254 | −1.2% |
| P worker (pipe) | `/items` | 32 | 18,739 | 19,438 | +3.7% |

So: **2–6% where the request and response are small, and nothing where the request already
spends its time elsewhere.** `/items` runs an ORM query and a 12 KB render, so six saved
syscalls on each side vanish into noise — the spread *within* one binary is larger than the
difference between them (T's `/items` c=32 repeats were 8,006 / 8,275 / 8,448).

Two caveats, stated rather than buried. The A/B is **not a clean isolation**: the earlier
binary is the commit before the buffering pass, which also predates two other commits, so
part of the gain belongs to those. And the large 40-read figure buys the *least* throughput,
because in practice nginx sends the whole CGI environment in **one** `PARAMS` record — the
twelve-record request is what this front-end tolerates, not what it receives.

**A syscall cut is a fixed cost removed, not a proportional one.** It pays where the request
is otherwise cheap, which is exactly the `GET /` arm a deployment comparison leads with.

## The crossover — latency under concurrency

The table above holds concurrency at 1 and the sweep holds it at 12. Neither answers the
question a deployment faces: at what load does the resident worker's advantage stop being
visible. `scripts/crossover.php` holds it at each of 1..16 with N closed-loop client
processes, one per connection, each running the same blocking loop `latency.php` uses.

Median of 3 runs x 400 iterations per client, milliseconds. The ratio column is
**cold-over-warm** (F/P), the direction that reads larger when the resident model is further
ahead — the convention `scripts/compare_runs.py` also uses.

| conc | P stokehold | R RoadRunner | F nginx+php-fpm | U stokehold unix | T stokehold TCP | F/P | F/R |
|---|---|---|---|---|---|---|---|
| 1 | 0.584 | 0.592 | 1.234 | 1.521 | 1.548 | **2.11×** | 2.08× |
| 2 | 0.573 | 0.591 | 1.204 | 1.421 | 1.361 | 2.10× | 2.04× |
| 4 | 0.589 | 0.649 | 1.239 | 1.382 | 1.339 | 2.10× | 1.91× |
| 8 | 0.722 | 0.748 | 1.382 | 1.617 | 1.604 | 1.91× | 1.85× |
| 12 | 0.836 | 0.836 | 1.507 | 1.936 | 1.870 | 1.80× | 1.80× |
| 16 | 0.917 | 0.980 | 1.791 | 2.119 | 2.110 | **1.95×** | 1.83× |

**The advantage does not cross over.** It is ~2.1× at concurrency 1, dips to ~1.8× in the
middle, and is back to ~2.0× at 16. That is the opposite of the intuition that a
per-request boot must eventually be hidden by concurrency, and the CPU numbers below are
why: the cold arm saturates its CPU budget at ~8,500 rps while the warm arm reaches
~18,000, so the cold arm is the one already queuing and the gap has no reason to close.

P and R agree to within 10% at every concurrency in this pass, and to within 2% at c=1 and
at c=12, where they are identical to three decimals.

On `/` the same pass gives ~1.7–1.8× (F/P) and ~1.5–1.6× (F/R).

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

| arm, conc 32 | rps | total cores | busiest % of 12 | **total CPU per request** |
|---|---|---|---|---|
| P worker (warm) | 18,485 | 7.93 | 66% | **429 µs** |
| T spawn_cgi (cold) | 7,951 | 9.76 | 81% | **1,228 µs** |

Both close arithmetically: `18,485 × 429 µs = 7.93 cores` and `7,951 × 1,228 µs = 9.76
cores`. The per-request model costs ~1.23 ms of CPU per request against ~0.43 ms, a ratio
of 2.86 — and since the cold arm's 1.23 ms is its entire budget, adding workers cannot make
it faster.

Two numbers in this table moved in opposite directions when the front-end was fixed, and the
movement is itself informative. The warm arm's CPU per request fell from 666 µs to 429 µs
(the front-end's share was pure waste), but its *utilisation* fell too, from 86% to 66% —
because 12 workers now serve 18,485 rps in the same wall clock with less CPU each, leaving
more of the machine idle. The cold arm's utilisation did not change, because it never had
any waste to remove: its CPU is the framework boot, which is what it is measuring.

The idle cores are not headroom; they are the cost of booting PHP and the framework on every
request, plus the duty cycle below.

The cold model's remaining idle time is the other half of the same story. `php-cgi` is
single-threaded and its request cycle is not all CPU: some of it is waiting on its own
socket for the next request. Twelve such processes leave a core or two unscheduled, and no
amount of client concurrency fixes that, because concurrency is capped by the 12 children —
a php-cgi child serves one request at a time. The cold model has a duty cycle, and its
ceiling is the pool size times that duty cycle.

## The confounds, stated

**Why ~2.15× here and 3.30× published, on the same application and the same route.** The ratio
is the boot divided by the work, so it moves with the work. My warm arm does 0.608 ms of work
where the published RoadRunner row does 0.4647 ms — this page carries more per request (an
ORM query and a 12 KB render against the published entry script's own mix), so the same
~1.0 ms boot is a smaller multiple of it. Neither figure is wrong: a ratio is only
comparable between runs whose warm-arm cost is comparable, and these differ by ~31%.
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
- **The leftover-php-cgi guard could not see the arms it was guarding.** It matched the
  literal string `php-cgi -b`, but arms T and U spawn PHP through the `php-cgi-bench`
  wrapper, which puts its `-d` flags *before* `-b`:
  `/usr/bin/php-cgi -d opcache.enable_cli=1 … -b 127.0.0.1:19300`. The pattern therefore
  matched **0** of the 12 children a running arm actually had — measured, on the bench host:
  0 while twelve were alive, and still 0 after a `kill -9` of the server left all twelve
  orphaned. The "8 strays" a previous run reported were leftovers from older configs that
  invoked `/usr/bin/php-cgi` directly, which is why the number looked plausible. It now
  matches `-b` as its own word through `ps -eww` and runs after **every** arm, refusing to
  continue if a leak cannot be cleared; a leak can no longer reach an arm that is measured.
- **php-fpm ran as `www-data` against a `competition`-owned SQLite database** and 500'd
  every request; the pool now runs as the checkout's owner.

Three more were found by *measuring*, rather than by reading, and each is described where
it belongs above:

- **A whole-payload `from_utf8_lossy` in the response header parser**, which both cost 5.2%
  of the server's CPU per request and could be made to move the header terminator by a
  non-UTF-8 byte inside the body. See "Where the warm arm's 10% went".
- **A bit-by-bit CRC-32C** on every response frame, 14.8–19% of the server's CPU per
  request. Same section.
- **A second full scan for the separator the header parser had already found.** Same
  section.

And one that was found by *not* trusting two measurements that agreed: the 10% deficit
between P and R was small enough to call agreement, which is why it took a fourth pass
(CPU attribution) to show it was stokehold's own waste rather than a server difference. The
lesson is the same one this document keeps relearning: **two numbers agreeing does not mean
either is right.**

