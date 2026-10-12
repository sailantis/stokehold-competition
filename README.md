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

## Reproducing

```bash
composer install
php seed.php
bash scripts/bench.sh
```

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

**When a ratio surprises you, measure whose CPU it is before theorising.** The
`diag-*` scripts are here because that is how the largest single finding in this
repository was made: a 10% throughput gap between two servers was a 3x difference
in *server* CPU per request, invisible in wall clock, and fixing it moved the
result by more than any configuration change in the history of the harness.
