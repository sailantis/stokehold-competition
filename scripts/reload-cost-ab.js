// What TLS costs on a deployment that never negotiates it.
//
// The claim under test is "with no `[server.tls]` there is no peek, no branch, and no TLS value
// is constructed". The estimator that can settle it is a *within-round ratio with the arm order
// rotated*, because a blocked sweep on a host that drifts charges that drift to whichever arm ran
// last — the same reason `ab-perf.sh` exists on the Linux side.
//
// The two arms are two *binaries*:
//
//   A  `206b41f`  the last commit before any TLS code existed
//   B  current HEAD, which carries the TLS work and everything after it
//
// both served with a config that has **no `[server.tls]` at all**, so any difference is what the
// TLS work added to the plaintext path. Comparing TLS-on against TLS-off inside one binary would
// measure the handshake instead, and nobody disputes the handshake.
//
// The claim is "nothing", so the expected answer is a ratio whose spread crosses 1.00 — which is
// what a null result looks like here, and it is reported rather than rounded to a point estimate.
//
// `static_files` is deliberately off: the static layer shares the listener, and its filesystem
// work has nothing to do with the TLS branch.

const autocannon = require('autocannon');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const A = { label: process.env.LABEL_A || 'pre-reload-68bfdcc', binary: process.env.BIN_A };
const B = { label: process.env.LABEL_B || 'head', binary: process.env.BIN_B };

if (!A.binary || !B.binary) {
  console.error('BIN_A and BIN_B are required');
  process.exit(2);
}

const PORT = Number(process.env.PORT || 18773);
const ROUNDS = Number(process.env.ROUNDS || 10);
const WARMUP = Number(process.env.WARMUP || 1);
const CONNECTIONS = Number(process.env.CONNECTIONS || 32);
const DURATION = Number(process.env.DURATION || 6);
const PATHNAME = process.env.PATHNAME || '/probe.txt';
const OUT = process.env.OUT || 'result.tsv';

const tmp = fs.mkdtempSync(path.join(process.env.TEMP, 'volucer-reload-'));
const docroot = path.join(tmp, 'public');
fs.mkdirSync(docroot, { recursive: true });
// 1 KiB, so the response is a body copy rather than a header-only answer.
fs.writeFileSync(path.join(docroot, 'probe.txt'), 'x'.repeat(1024));

// No `[server.tls]` anywhere. That is the whole point of the fixture.
const config = path.join(tmp, 'probe.toml');
const configText = `[server]
http = "127.0.0.1:${PORT}"
document_root = ${JSON.stringify(docroot)}
static_files = { enabled = true }
`;
fs.writeFileSync(config, configText);
const configBytes = Buffer.byteLength(configText);

function start(arm) {
  const child = spawn(arm.binary, ['serve', '--config', config], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return new Promise((resolve, reject) => {
    let out = '';
    const done = (err) => (err ? reject(err) : resolve(child));
    child.stdout.on('data', (d) => {
      out += d.toString();
      if (out.includes('press Ctrl-C to stop')) done();
    });
    child.stderr.on('data', (d) => {
      out += d.toString();
    });
    child.on('exit', (code) => done(new Error(`exited early (${code}): ${out}`)));
    setTimeout(() => done(new Error(`did not become ready: ${out}`)), 15000);
  });
}

async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const ended = new Promise((resolve) => child.once('exit', resolve));
  child.kill();
  const timer = setTimeout(() => {
    try { child.kill('SIGKILL'); } catch { /* already gone */ }
  }, 5000);
  await ended;
  clearTimeout(timer);
}

function run(binary) {
  return new Promise((resolve, reject) => {
    autocannon(
      {
        url: `http://127.0.0.1:${PORT}${PATHNAME}`,
        connections: CONNECTIONS,
        duration: DURATION,
      },
      (err, result) => {
        if (err) return reject(err);
        if (result.non2xx) {
          // A number produced by refusing requests is not throughput, and the whole project's
          // rule is that a shed request that reads as a win is the one mistake this harness
          // exists to prevent.
          return reject(new Error(`${result.non2xx} non-2xx responses`));
        }
        resolve({ rps: result.requests.average, p50: result.latency.p50, p99: result.latency.p99 });
      },
    );
  });
}

const rows = [];

async function round(index) {
  // The rotation: even rounds run A first, odd rounds B first, so neither arm is systematically
  // measured on a warmer or busier host. Results are keyed by *slot* rather than by label, which
  // is what makes an A-vs-A control run honest: with both arms sharing a label, keying by label
  // makes the second overwrite the first and the ratio reads exactly 1.0000 in every round for a
  // reason that has nothing to do with the servers.
  const aFirst = index % 2 === 0;
  let a = null;
  let b = null;

  const runOne = async (arm) => {
    const child = await start(arm);
    try {
      return await run(arm.binary);
    } finally {
      await stop(child);
    }
  };

  if (aFirst) {
    a = await runOne(A);
    await settle();
    b = await runOne(B);
  } else {
    b = await runOne(B);
    await settle();
    a = await runOne(A);
  }

  rows.push({ round: index, a, b });
  const ratio = b.rps / a.rps;
  console.log(
    `round ${index} (${aFirst ? 'A' : 'B'} first): ` +
      `${A.label} ${a.rps.toFixed(0)} rps, ${B.label} ${b.rps.toFixed(0)} rps, B/A ${ratio.toFixed(4)}`,
  );
  return ratio;
}

/// Let the arm that just ran release its port and its process tree before the next one starts,
/// so neither arm is measured while the other is still settling.
function settle() {
  return new Promise((resolve) => setTimeout(resolve, 1500));
}

(async () => {
  console.log(`config bytes: ${configBytes} (must be identical for both arms)`);
  console.log(`arm A: ${A.label} -> ${A.binary}`);
  console.log(`arm B: ${B.label} -> ${B.binary}`);
  console.log(`${ROUNDS} rounds, ${WARMUP} warmup discarded, c=${CONNECTIONS}, ${DURATION}s each`);

  for (let i = 0; i < WARMUP; i++) {
    await round(-1 - i);
  }
  rows.length = 0;

  const ratios = [];
  for (let i = 0; i < ROUNDS; i++) {
    ratios.push(await round(i));
  }

  const sorted = [...ratios].sort((x, y) => x - y);
  const median = sorted[Math.floor(sorted.length / 2)];
  const min = sorted[0];
  const max = sorted[sorted.length - 1];

  // The mean of the per-round *log* ratios, with a 95% interval. This is the quantitative part:
  // the spread says whether the point estimate is trustworthy, but the interval is what lets a
  // small real effect be distinguished from no effect at all. Reported in percent.
  const logs = ratios.map(Math.log);
  const meanLog = logs.reduce((sum, x) => sum + x, 0) / logs.length;
  const variance =
    logs.reduce((sum, x) => sum + (x - meanLog) ** 2, 0) / Math.max(logs.length - 1, 1);
  const se = Math.sqrt(variance / logs.length);
  const lo = (Math.exp(meanLog - 1.96 * se) - 1) * 100;
  const hi = (Math.exp(meanLog + 1.96 * se) - 1) * 100;
  const effect = (Math.exp(meanLog) - 1) * 100;

  console.log('');
  console.log(`per-round ratios: ${ratios.map((r) => r.toFixed(4)).join(' ')}`);
  console.log(`median B/A ${median.toFixed(4)}  spread [${min.toFixed(4)}, ${max.toFixed(4)}]`);
  console.log(
    `effect ${effect.toFixed(2)}%  95% CI [${lo.toFixed(2)}%, ${hi.toFixed(2)}%]  (n=${ratios.length})`,
  );
  // The verdict is drawn the way this project draws one: an interval containing zero is a null
  // result, whatever the point estimate says.
  const crosses = lo <= 0 && hi >= 0;
  console.log(
    crosses
      ? 'the interval contains 0 -> no measurable difference (the claim holds)'
      : 'the interval excludes 0 -> there IS a difference, and it needs attributing before it is claimed',
  );

  const header = 'round\tarm\trps\tp50_us\tp99_us';
  const lines = [header];
  for (const row of rows) {
    lines.push(`${row.round}\t${A.label}\t${row.a.rps.toFixed(1)}\t${row.a.p50}\t${row.a.p99}`);
    lines.push(`${row.round}\t${B.label}\t${row.b.rps.toFixed(1)}\t${row.b.p50}\t${row.b.p99}`);
  }
  lines.push(`# effect_pct\t${effect.toFixed(3)}`);
  lines.push(`# ci95_lo_pct\t${lo.toFixed(3)}`);
  lines.push(`# ci95_hi_pct\t${hi.toFixed(3)}`);
  lines.push(`# median_ratio\t${median.toFixed(4)}`);
  lines.push(`# spread_lo\t${min.toFixed(4)}`);
  lines.push(`# spread_hi\t${max.toFixed(4)}`);
  fs.writeFileSync(OUT, lines.join('\n') + '\n');
  console.log(`rows written to ${OUT}`);

  await new Promise((resolve) => setTimeout(resolve, 100));
  process.exit(0);
})().catch((err) => {
  console.error(`failed: ${err.message}`);
  process.exit(1);
});
