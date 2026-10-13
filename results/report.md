# Five ways to serve one page — 12 cores, one host

**Host:** Xeon Gold 5412U, 12 cores, 3884 MB, Ubuntu, PHP 8.3.35 NTS, nginx 1.24.0,
RoadRunner 2025.1.15, stokehold `91cc7b6`, wrk 4.1.0.
**Method:** `scripts/bench.sh`, 5 s per cell, 3 repeats, median reported, 12 workers/slots
in every arm, endpoints `GET /` and `GET /items`, no failed cells. Plus four extra passes:
`scripts/latency.php` (the sequential per-request methodology the published figures used),
`scripts/crossover.php` (the same latency at concurrency 1..16),
`scripts/diag-split.sh` and `scripts/diag-checksum.sh` (CPU per request, attributed across the
arm's process tree), and `scripts/ab-perf.sh` (four builds measured in rotating order inside one
round, which the blocked sweep above cannot do).

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
>
> **This revision also settles a question the sweeps above could not: is the crc32c fix still
> worth what it claimed?** It is worth more than the report previously implied, and it is the
> *only* thing that puts the warm arm ahead of RoadRunner. Measured by an interleaved A/B —
> four variants, every one measured inside the same round, the starting order rotated, 7
> rounds × 6 cells = 168 measured cells and 0 failures — the current build is **+10.2% to
> +16.3%** over the same build with **only** `crc32c` reverted to the hand-written loop it
> replaced, in **all 42 paired cells**; and that reverted build is **−5.8% to −12.9% behind
> RoadRunner in every cell of every round**. CPU attribution agrees to the microsecond: the
> fix removes **59 µs of server CPU per request** (184 → 125 µs on `/items` at c=32, −32%) and
> leaves the PHP column where it was. See "Is the warm arm's lead still there?" below, and
> hazards 50–51 in the stokehold plan. The two CPU-attribution tables *below* are still the
> carried-over ones, but this revision adds a current attribution for exactly the three builds
> the question is about.

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
>
> **A fifth pass, because the sweeps kept disagreeing with each other.** A blocked sweep
> measures one arm at a time, so a host that drifts over twenty minutes charges that drift to
> whichever arm ran last — which is how a 22% "effect" once appeared and then reversed sign
> when the same two binaries were interleaved instead (hazard 49). `ab-perf.sh` measures every
> variant inside the same round and rotates the starting order, so the estimator is a
> within-round ratio and the spread across rounds is the error bar. That is the pass that
> answers "is the lead still there", and it found that the lead is the `crc32c` fix, whole.

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
| Is the crc32c fix still worth what it claimed? | **it is worth more, and it is the whole lead** - +10.2% to +16.3% over the reverted build, which is 5.8-12.9% *behind* RoadRunner | interleaved A/B, 168 cells |
| What does it cost, per process? | **59 µs of server CPU per request** (184 → 125 µs), PHP column unchanged, and flat across c=8..32 | CPU attribution, 3 builds |
| Is the c=16 loss a crossover? | **no - a ~1% deficit spread over c=16-20, every round's spread crossing 1.00** | dense A/B, 96 cells |
| Is anything actually worse? | **the tail - p99 1.6 → 10.4 ms from c=12 to 24 while RoadRunner stays at 1.8 → 2.7 ms** | dense A/B, same 96 cells |

Everything below is the detail behind that table.

## `GET /` — the server and the model

| arm | server | model | c=1 | c=4 | c=8 | c=16 | c=32 |
|---|---|---|---|---|---|---|---|
| **P** | stokehold | warm worker, pipe | 3,268 | 12,970 | 23,278 | 34,394 | 36,008 |
| **R** | RoadRunner | warm worker, pipe | 2,999 | 11,143 | 19,730 | 33,462 | 35,513 |
| **F** | nginx + php-fpm | cold, unix socket | 1,823 | 6,504 | 11,638 | 18,365 | 17,960 |
| **U** | stokehold | cold, unix socket | 1,571 | 5,631 | 9,419 | 14,397 | 16,126 |
| **T** | stokehold | cold, loopback TCP | 1,534 | 5,866 | 9,736 | 14,212 | 16,744 |

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
| **P** | stokehold | warm worker, pipe | 1,790 | 6,893 | 11,523 | 16,696 | 18,655 |
| **R** | RoadRunner | warm worker, pipe | 1,727 | 6,535 | 10,957 | 17,190 | 17,804 |
| **F** | nginx + php-fpm | cold, unix socket | 808 | 3,049 | 5,430 | 8,412 | 8,325 |
| **U** | stokehold | cold, unix socket | 654 | 2,696 | 4,616 | 7,240 | 8,179 |
| **T** | stokehold | cold, loopback TCP | 651 | 2,838 | 4,736 | 7,015 | 8,014 |

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

## Is the warm arm's lead still there?

That question was asked because the answer looked like no. Five committed sweeps compared against
each other show the lead at `ace1449` reading 1.20× and the next sweep, on **identical warm code**,
reading 1.09× — and the sweep after that ~3% below it in every cell. A trend cannot answer a
question at that size, because the thing being compared is not the only thing that moved: in the
sweep that looked like a regression, **every** arm fell, including RoadRunner and nginx + php-fpm,
which none of the intervening commits touch.

So this is a different instrument. Four variants, each measured **inside the same round**, with
the starting order rotated by round so a drift of any shape charges every variant equally:

| variant | what it is |
|---|---|
| `new-req` | current build, `checksum = "required"` — what every table above used |
| `new-opt` | current build, `checksum = "optional"` — the knob hazard 41 added |
| `old-req` | current build with **only** `crc32c` reverted to the hand-written loop |
| `rr` | RoadRunner — shares no code with any of the other three |

`rr` is the control and the reason the result is legible. 7 rounds × 2 endpoints × 3 concurrency
levels = **168 measured cells, 0 failed**, and the leak guard reports clean after every variant.
The estimator is a ratio computed within a round, so the spread across the seven rounds is the
error bar — the thing a blocked layout throws away. Raw rows: `results/ab-perf.tsv`, in
`results/cpu-per-request.tsv` for the attribution, reproducible with `scripts/ab-perf.sh` and
`scripts/diag-checksum.sh`.

### The `crc32c` fix is worth 10–16%, and it is the whole lead

The revert is **targeted**, and that is what makes the number mean something. Building the commit
before the fix would have been simpler and would have isolated nothing: it is twenty commits back
and bundles the FastCGI parser de-allocation (5.2%), the single-pass `parse_response` (5.2%) and
the request-path copies along with the checksum. So only `header::crc32c` was restored to the
bit-by-bit loop it replaced — in a second checkout, with the two binaries confirmed to differ in
behaviour not at all, because both return **byte-identical** bodies for both endpoints and the
pinned `crc32c_matches_the_standard_check_value` test still passes on the reverted tree.

| ratio, median over 7 rounds | `/` c=8 | `/` c=16 | `/` c=32 | `/items` c=8 | `/items` c=16 | `/items` c=32 |
|---|---|---|---|---|---|---|
| **`crc32c` fix** (`new-req`/`old-req`) | **+11.8%** | **+11.4%** | **+16.3%** | **+10.2%** | **+12.1%** | **+13.7%** |
| checksum option (`new-opt`/`new-req`) | +2.0% | +2.9% | +2.5% | +3.0% | +2.7% | +2.8% |
| lead over `rr` (`new-req`/`rr`) | +18.0% | +4.6% | +4.2% | +3.3% | **−1.7%** | +7.0% |
| **pre-fix vs `rr`** (`old-req`/`rr`) | **+5.3%** | **−6.5%** | **−9.1%** | **−5.8%** | **−12.9%** | **−6.2%** |

The first row is positive in **all 42 paired cells** — the spread never crosses 1.00 anywhere.
The last row is negative in all six cells of every round. That is the answer, and it is stronger
than "the effect is still there": **the pre-fix build is behind RoadRunner everywhere**, by
5.8–12.9%, so the `crc32c` fix is not one optimization among several that happen to sum to a lead.
It is the thing that turns a consistent deficit into a consistent lead, and nothing since has
either extended it or spent it.

Per-round spreads, so the claim can be checked rather than believed:

| ratio | `/` c=32 | `/items` c=32 |
|---|---|---|
| `crc32c` fix | 1.163× `[1.131..1.172]` | 1.137× `[1.115..1.154]` |
| checksum option | 1.025× `[1.000..1.049]` | 1.028× `[0.995..1.055]` |

The difference between those two rows is the whole methodological point: the fix's spread is far
from 1.00, the option's is not. **A median that is positive while its own spread straddles 1.00
is a real cost reported through a noise floor larger than it is.**

### The mechanism agrees, in the column it predicted

A ratio says a cost exists; CPU attribution says whose it is. Per request on `/items`, median of
three rounds at each concurrency:

| build | c | server µs | PHP µs | total µs | rps |
|---|---|---|---|---|---|
| `old-req` — bit-by-bit loop | 32 | **184** | 287 | 471 | 16,957 |
| `new-req` — crate, hardware CRC32 | 32 | **125** | 283 | 408 | 19,428 |
| `new-opt` — crate, checksum off | 32 | **121** | **281** | 402 | 19,414 |
| `old-req` | 16 | 181 | 289 | 470 | 15,627 |
| `new-req` | 16 | 122 | 284 | 406 | 17,581 |
| `new-opt` | 16 | 119 | 282 | 401 | 17,708 |

The fix removes **59 µs of server CPU per request (184 → 125, −32%)** and leaves the PHP column
where it was (287 → 283). That is exactly what it should do and no more: the server hashes every
response once, while the worker's hash is the SDK's `hash('crc32c', …)`, which was already
hardware-accelerated. The same column moves 181 → 122 at c=16. So the 10–16% in throughput is a
~13% cut in total CPU per request, arrived at by two instruments that share nothing but the host.

Two things this does **not** say, both visible above. The warm arm at 19,400 rps uses **7.8 of 12
cores**, so it is not CPU-saturated at this load — which is why the throughput gain is a little
smaller than the CPU gain, and why it is not uniform across concurrency. And the PHP column is not
*identical* across the three builds; it moves by ~6 µs in the same direction as the server column
because the worker's hash is part of what the option removes, and the residue is run noise.

**And the per-request cost is flat in concurrency, for both servers**, which is what makes the
one losing cell look like noise rather than a mechanism. Server CPU per request on `/items`,
median of three rounds at each level:

| concurrency | stokehold | RoadRunner | stokehold's advantage |
|---|---|---|---|
| c=8 | 124 µs | 159 µs | −35 µs |
| c=12 | 121 µs | 160 µs | −39 µs |
| c=16 | 123 µs | 154 µs | −31 µs |
| c=20 | 124 µs | 151 µs | −27 µs |
| c=24 | 124 µs | 152 µs | −28 µs |
| c=32 | 126 µs | 152 µs | −26 µs |

Stokehold's per-request cost does not move at all across a 4× range of offered load, and
RoadRunner's moves by 9 µs. If c=16 were a genuine crossover — the point at which stokehold's
12 slots stop covering the offered concurrency — the stokehold column would be the one to bend
there. It does not bend anywhere. What *does* move is the tail: see "A single cell that is not a
crossover, and the tail that is".

### A correction: hazard 41 measured the checksum against half its own cost

Hazard 41 concluded the optional checksum was "worth about 0.26%", from a microbenchmark that
encoded a whole response with the SDK 50,000 times and compared checked against unchecked. That
number is not wrong, it is **incomplete in a systematic way**: it timed the *Rust-side frame
encoding*, and `crc32c` is computed **twice** per response — once by the PHP worker that writes the
`BODY` frame, and once by the server that reads it back. The worker's copy is the larger half.

Measured end to end the cost is **~6 µs of CPU per request, about 1.5%** (server 125 → 121, PHP
283 → 281), and the throughput medians are **+2.0% to +3.0%**. So the knob is worth several times
what hazard 41 claimed — but with the caveat above: its spread crosses 1.00 in four of the six
cells, so it should be read as a small, real, now-measured saving rather than as a headline. The
attribution is what makes it trustworthy; the throughput medians alone would not.

For this report's purposes the recommendation does not change, and it is worth stating why: the
checksum's value is integrity, and 3% is not a reason to turn off a corruption check. What changes
is that the trade is now priced correctly instead of being dismissed as 0.26%.

### A single cell that is not a crossover, and the tail that is

The table above has one cell where RoadRunner wins: `/items` at c=16, −1.7%. The obvious
reading is a crossover — stokehold's pool has 12 slots and c=16 is the first concurrency
above it — so it was chased with a denser sweep: the same two variants at c=12, 14, 16, 18,
20 and 24, eight rounds, a balanced two-variant rotation so each variant starts first four
times. 96 cells, none failed.

| concurrency | stokehold | RoadRunner | stokehold's lead | per-round spread |
|---|---|---|---|---|
| c=12 | 15,678 | 15,482 | +1.3% | 1.003–1.041 |
| c=14 | 16,932 | 16,745 | +1.1% | 0.985–1.018 |
| **c=16** | 17,560 | 17,759 | **−1.1%** | 0.965–1.018 |
| **c=18** | 18,010 | 18,250 | **−1.3%** | 0.971–1.001 |
| c=20 | 18,336 | 18,413 | −0.4% | 0.979–1.017 |
| c=24 | 18,827 | 18,272 | +3.0% | 1.009–1.055 |

**There is no crossover.** The deficit is real but shallow (−1%, or about 200 rps out of
18,000) and it sits in a band from c=16 to c=20, not at a threshold; the spread crosses 1.00
at c=14, 16, 18 and 20, and the ratio wobbles non-monotonically. At this size a single
concurrency level is not a meaningful unit — the honest statement is that **between
concurrency 16 and 20 the two servers are within about 1% of each other, and outside that
band stokehold leads.** Attributing the c=16 cell to slot exhaustion would have been a story
the data does not support.

The dense sweep did turn up something the sparse one could not: **a tail-latency divergence
that has nothing to do with throughput.**

| concurrency | stokehold p99 | RoadRunner p99 | ratio |
|---|---|---|---|
| c=12 | 1,640 µs | 1,760 µs | 0.93× |
| c=14 | 2,195 µs | 1,930 µs | 1.14× |
| c=16 | 3,470 µs | 2,105 µs | 1.65× |
| c=18 | 5,255 µs | 2,275 µs | 2.31× |
| c=20 | 6,770 µs | 2,415 µs | 2.80× |
| c=24 | 10,425 µs | 2,690 µs | 3.88× |

RoadRunner's tail is **flat** above its slot count, which is what a pool that holds a queue
looks like. Stokehold's grows without bound and its p50 stays *better* than RoadRunner's at
every level, so the mean is fine and the tail is not. A p99 that grows with offered load while
the median improves is a signature of **queueing with no bound on the queue**, not of
overload — the work is not slower, it is waiting longer before it starts.

The mechanism is a hypothesis and is labelled as one. `pick_slot` (hazard 50's file,
`worker_pool/mod.rs:355`) advances an atomic cursor and then takes **each candidate slot's
mutex** until it finds one whose `is_available()` is true; `is_available()` is
`exchange.is_some() && child has not exited` — it means *the worker is healthy*, not *the slot
is free*. The mutex is then held across the whole request, so at c=32 thirty-two connection
threads contend for twelve slot mutexes with no fair queue and no backpressure. That would
produce exactly this shape.

This is worth recording as a finding rather than a task because it is not a throughput problem
and fixing it would not move any number in this report. It is a *deployment* property: a
`p99` that reaches 10 ms at 24 concurrent connections is visible to a user in a way that a 1%
throughput deficit is not, and a resident-worker server that is faster on average and worse at
the tail is a different proposition from one that is faster on both.

#### The hypothesis, tested

The pool now measures it. `wait_us` accumulates, per slot, the time each request spent between
asking for a slot and holding one, and counts each wait into powers of two so a percentile can
be read out of it. Both figures are produced *inside the server* and printed at shutdown
(stokehold `4dd402a`, `a6df392`), so they cannot include anything a client did.
`scripts/diag-slots.sh` drives it.

Two experiments were run on the benchmark host, three repeats each, `/items`, 8 s per run.

**First, is the client at fault?** The harness drives `wrk` as `-t$c -c$c`, so concurrency *is*
the thread count, and at c=32 the load generator owns 32 threads on a 12-core box. Holding
concurrency at 32 and varying only the thread count changes nothing on the server side:

| client threads | client p50 | client p99 | pool mean wait | pool p99 wait |
|---|---|---|---|---|
| 2 | 1.16 ms | **17.80 ms** | 895 µs | 16.4 ms |
| 32 | 1.19 ms | **18.33 ms** | 898 µs | 16.4 ms |

p99 moves by 3%, and the pool's own figures do not move at all. **The load generator is not the
cause.** This hypothesis was mine, it was plausible, and the measurement refutes it.

**Second, does it scale with excess clients, as queueing must?** Concurrency equals threads:

| concurrency | excess over 12 workers | client p50 | client p99 | pool mean | pool p50 | pool p99 | pool mean as share of time in system | client `p99−p50` | pool `p99−p50` |
|---|---|---|---|---|---|---|---|---|---|
| 12 | 0 | 0.71 ms | 1.68 ms | 34 µs | 2 µs | 1.02 ms | 4% | 0.97 ms | 1.02 ms |
| 16 | 4 | 0.79 ms | 3.94 ms | 157 µs | 3 µs | 2.05 ms | 17% | 3.15 ms | 2.05 ms |
| 20 | 8 | 0.88 ms | 7.68 ms | 325 µs | 4 µs | 8.19 ms | 30% | 6.80 ms | 8.19 ms |
| 24 | 12 | 0.97 ms | 10.74 ms | 509 µs | 4 µs | 8.19 ms | 40% | 9.77 ms | 8.19 ms |
| 32 | 20 | 1.16 ms | 18.98 ms | 906 µs | 19 µs | 16.4 ms | 54% | 17.82 ms | 16.37 ms |

Three things in that table are the finding.

- **The growth starts at concurrency 13, not at a plateau.** This kills a hypothesis I had
  offered earlier in this work — that a request is served the instant the cursor points at a
  free slot, so the wait is a step at c = workers + 1 and flat thereafter. A step shape would
  be *scheduling*: wait for the one request already in front of you. This shape — 34, 157,
  325, 509, 906 µs across 0, 4, 8, 12, 20 excess clients — is *accumulating queue*: each new
  client waits for everything queued ahead of it. The old docstring's claim that the scan
  "never blocks on a busy worker" is not merely imprecise, it described a design that is not
  what runs.
- **It is unfairness, not slowness.** The pool's median wait is 2–19 µs while its p99 is
  1–16 ms. Most requests are served immediately through an uncontended mutex; a few wait for
  whole requests. That is a queue with no bound and no fairness, and it is exactly the shape
  the client sees: the pool's own `p99−p50` tracks the client's `p99−p50` at every level
  (1.02 vs 0.97 ms, 2.05 vs 3.15, 8.19 vs 6.80, 8.19 vs 9.77, 16.37 vs 17.82). The tail is
  the pool's, and it is 84–105% of the client's excess over its own median.
- **The mean is legitimate and it is a real cost.** The pool's mean wait is a growing share of
  the client's mean time in system — 4% at c=12 rising to **54% at c=32**, where a request
  spends 0.91 ms of its 1.69 ms waiting for a slot. It is not pure tail: half the request's
  average latency at high concurrency is spent waiting for a worker that is busy with someone
  else, which is the throughput plateau in another form. A fair queue would not remove that
  time; it would spread it evenly instead of concentrating it, which is a latency *variance*
  fix rather than a latency fix.

So the hypothesis is confirmed with a correction: the pool does not block waiting for a
specific busy worker by round-robin luck, as the original wording had it. It accumulates an
unbounded queue behind mutexes taken without fairness, and the queue grows with offered load
because nothing pushes back.

**What this does not yet say** is which change is worth making. The measurement identifies the
defect and its magnitude; it does not compare candidate fixes. Giving the pool a fair queue, or
making the scan take `try_lock` so a request skips a busy slot instead of queueing for it, are
both consistent with this data and would need to be built and measured. What is now settled is
that there *is* something to fix, that it is in `pick_slot`, and that it is worth 0.9 ms of mean
latency and a 16 ms p99 at c=32 — which is enough to justify the work that a hypothesis alone
was not.

#### The fair queue, built and measured

The free list was chosen over `try_lock` for a reason the data already implied: **the mean wait is
structural.** 32 clients against 12 workers at ~600 µs each means ~20 requests in flight beyond
the workers, and no scheduling change removes that time — it is Little's law, and it is why the
two sweeps above agree on ~900 µs at c=32 despite being otherwise different experiments. What a
fix *can* change is who that time is charged to. `try_lock` scanning for a free slot is a race
rather than a fairness mechanism, and at c=32, where the damage is, all twelve slots are usually
busy — there is little free to skip to. The fair queue makes a request wait for the slot it will
actually use. `pick_slot`, the cursor and the healthy-not-free test are gone, replaced by a lease
(stokehold `e2b031e`).

Same two sweeps, on the idle host, three repeats per level:

| concurrency | rps before → after | client p50 | client p99 | pool mean wait | pool p99 wait |
|---|---|---|---|---|---|
| 12 | 15,686 → 16,342 (**+4.2%**) | 0.71 → 0.69 ms | 1.68 → 1.41 ms (−16%) | 34 → 0 µs | 1.02 → 0.008 ms |
| 16 | 17,548 → 19,884 (**+13.3%**) | 0.79 → 0.75 ms | 3.94 → 1.57 ms (−60%) | 157 → 30 µs | 2.05 → 0.51 ms |
| 20 | 18,581 → 22,114 (**+19.0%**) | 0.88 → 0.85 ms | 7.68 → 1.78 ms (−77%) | 325 → 123 µs | 8.19 → 1.02 ms |
| 24 | 18,799 → 22,787 (**+21.2%**) | 0.97 → 0.99 ms | 10.74 → 2.24 ms (−79%) | 509 → 271 µs | 8.19 → 2.05 ms |
| 32 | 18,982 → 22,360 (**+17.8%**) | 1.16 → 1.35 ms | 18.98 → 3.68 ms (−81%) | 906 → 625 µs | 16.4 → 4.10 ms |

Three things there go beyond what was predicted, and the first is the one to be careful about.

- **Nothing was shed to achieve it.** A bounded queue that refuses under load would look exactly
  like a tail improvement while quietly converting throughput into 503s, so this was checked
  directly: `wrk` reports non-2xx responses as an explicit line and printed **none** at c=16, 24
  or 32, and the server logged no refusal. Every response counted above was a success.
- **Throughput rose too, by 13–21%.** That was not the goal and was not predicted. It is
  consistent with the mechanism: the old scan did real work under contention — locking each
  candidate, calling `try_wait` on each, and at c=32 walking the whole array before blocking on
  one slot — and that work is paid per request, on 12 cores, 19,000 times a second. A free list
  pop costs about what an uncontended mutex costs.
- **The median cost far less than predicted.** The estimate was p50 rising from 1.16 ms to
  ~1.5–1.7 ms at c=32 as the mean got shared out; it went to 1.35 ms. Right direction, too
  pessimistic, and the likely reason is that a fair queue also produces 40% fewer requests that
  spend time waiting at all, so there is less total queueing to share out.

The trade that *was* expected did occur: **at c=32 the median is 16% worse** while the p99 is 81%
better. That is the fairness doing what it was approved to do — the request that would have been
served on contact now shares the queue — and it is confined to the range where there is something
to share, because at c=12 the median is slightly *better*.

RoadRunner for contrast, from the dense sweep: at c=24 it measured 2.70 ms p99 with a 1.23 ms
median. The fair queue gets 2.24 ms p99 with a 0.99 ms median — better on both, which is the first
time this project has been able to say that about the tail.

#### The gain re-measured interleaved, and it is larger

The before/after table above is a blocked layout, and the +13–21% in it was the one number there that
the data could not settle on its own: a host that drifts charges the drift to whichever build ran
last, and this repository has already published a **22% "effect" that reversed sign** the moment two
binaries were interleaved instead of blocked (hazard 49). So the same two binaries were rebuilt and
measured again inside a single round — `diag-slots.sh` in its A/B mode, both builds started in
rotating order, RoadRunner included as a control that shares no code with either. 7 rounds × 3
variants × 2 concurrency levels = **42 measured cells, 0 discarded**, after a discarded warm-up pass
per round so that the first variant of round 1 pays for the cold binary and cold fs cache only in a
row that is thrown away.

Per-round ratios, so the claim can be checked rather than believed:

| concurrency | new / pre-fair | spread over 7 rounds | new / RoadRunner | pre-fair / RoadRunner |
|---|---|---|---|---|
| **c=24** | **1.245× (+24.5%)** | 1.223–1.271 | 1.272× (+27.2%) | 1.030× (+3.0%) |
| **c=32** | **1.229× (+22.9%)** | 1.197–1.244 | 1.302× (+30.2%) | 1.057× (+5.7%) |

The spread never crosses 1.00 at either level, and every one of the 14 paired comparisons is the
same way. The control confirms it is stokehold that moved rather than the host: on the same rounds
**the pre-fair binary measured +3.0% and +5.7% over RoadRunner — the same band hazard 51 established
for that binary in the interleaved A/B at the top of this report (+4.2% and +7.0% here, and −1.7% in
the one `/items` c=16 cell of that pass)** — while the current build sits at +27% and +30%. The old
build still lands exactly where it always did; the new one is 23–25% above it. So the blocked layout
*understated* the gain, and the fair queue is not a few-percent scheduling change: it is the second
largest single effect this repository has measured, behind only the `crc32c` fix.

The pool's own columns move with the throughput rather than against it. Median over the seven
rounds, measured inside the server:

| concurrency | build | mean wait | wait p50 | wait p99 | client p50 | client p99 |
|---|---|---|---|---|---|---|
| c=24 | pre-fair | 522 µs | 8 µs | 8,192 µs | 1.00 ms | **10.92 ms** |
| c=24 | **fair** | 263 µs | 256 µs | **2,048 µs** | 0.98 ms | **2.19 ms** |
| c=32 | pre-fair | 887 µs | 64 µs | 16,384 µs | 1.21 ms | **17.44 ms** |
| c=32 | **fair** | 587 µs | 1,024 µs | **4,096 µs** | 1.28 ms | **3.47 ms** |

Three things to read there. **The p99 halves twice over** (10.92 → 2.19 ms at c=24, 17.44 → 3.47 ms at
c=32), and it does so *while* the mean wait falls (522 → 263 µs). **The p50 rises**, from 8 µs to
256 µs, which is the fairness being visible: the request that used to be served on contact now
shares the queue, so it waits a little and the unlucky request no longer waits 10 ms. And the client
p50 at c=32 pays 0.07 ms for it (1.21 → 1.28 ms) — the same trade the blocked sweep showed, at less
cost.

**Nothing was shed to achieve any of it.** A bounded queue that refuses under load would look
exactly like this while quietly converting throughput into 503s, so the check was run against this
binary directly rather than inferred from the log: three 8-second runs at c=24 with `wrk`'s full
summary printed, and **no `Non-2xx` line, no `Socket errors` line, in any of them** — 232,751 /
233,591 / 235,206 successful requests, ~23,100 rps, with the server logging no refusal. The pool has
a 500 ms slot-wait ceiling and it never reached it. Raw rows: `results/slot-waits-fair-ab-c24.tsv`
and `-c32.tsv`, the run's full output in `slot-waits-fair-ab-run.log`, reproducible with
`scripts/diag-slots.sh` (`VARIANTS=new,prefair,rr`) and `scripts/slots-report.py`.

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

