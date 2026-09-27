const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { recordMetric } = require('../../lib/build-metrics.cjs');
const { seconds, duration, summarizeEvents, summarizeWorkflow, eventsForAttempt } = require('../../build/workflow-report.cjs');

test('report separates queue and execution instead of summing parallel jobs', () => {
  const created = '2026-01-01T00:00:00Z';
  const started = '2026-01-01T00:05:00Z';
  const ended = '2026-01-01T00:15:00Z';
  const report = summarizeWorkflow({ id: 1, created_at: created }, [1, 2].map(id => ({
    id, name: `Build PHP ${id}`, created_at: created, started_at: started, completed_at: ended,
    steps: [{ name: 'Compile', started_at: started, completed_at: ended }],
  })), ended);
  assert.equal(report.elapsedThroughReportSeconds, 900);
  assert.deepEqual(report.jobs.map(job => [job.queueSeconds, job.runSeconds]), [[300, 600], [300, 600]]);
  assert.equal(seconds(undefined, ended), null);
  assert.equal(duration(null), 'unavailable');
});

test('partial reruns exclude previous attempts and idle time between attempts', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'metrics-attempt-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [key, value] of Object.entries({ PHP_DARWIN_METRICS: path.join(root, 'events.jsonl'),
    GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '2' })) {
    const previous = process.env[key];
    t.after(() => { if (previous === undefined) delete process.env[key]; else process.env[key] = previous; });
    process.env[key] = value;
  }
  recordMetric({ kind: 'source', result: 'restored' });
  const current = JSON.parse(fs.readFileSync(process.env.PHP_DARWIN_METRICS, 'utf8'));
  const events = [current, { ...current, attempt: '1' }, { ...current, run: '456' },
    { kind: 'source', result: 'built' }];
  assert.deepEqual(eventsForAttempt(events, 123, 2), [current]);
  const report = summarizeWorkflow({ id: 123, run_attempt: 2,
    created_at: '2026-01-01T00:00:00Z', run_started_at: '2026-01-02T00:00:00Z' }, [], '2026-01-02T00:05:00Z');
  assert.equal(report.attempt, 2);
  assert.equal(report.elapsedThroughReportSeconds, 300);
});

test('report distinguishes source builds, cache reuse and archive reuse', () => {
  const summary = summarizeEvents([
    { kind: 'prefetch', result: 'complete', count: 2, elapsedMs: 300 },
    { kind: 'source', result: 'built', compileMs: 1000, bottleMs: 20, uploadMs: 10 },
    { kind: 'source', result: 'restored-after-wait', waitedMs: 500 },
    { kind: 'checkpoint', result: 'restored' },
  ]);
  assert.equal(summary.counts['prefetch/complete'], 1);
  assert.equal(summary.counts['source/built'], 1);
  assert.equal(summary.counts['source/restored-after-wait'], 1);
  assert.equal(summary.counts['checkpoint/restored'], 1);
  assert.deepEqual(summary.phases, { prefetchMs: 300, compileMs: 1000, bottleMs: 20, uploadMs: 10, waitedMs: 500 });
});

test('successful compilation does not conceal a failed cache upload', () => {
  const summary = summarizeEvents([{ kind: 'source', result: 'built', formula: 'php@8.6',
    key: 'exact-key', saved: false, saveError: 'Connection timed out', compileMs: 1000 }]);
  assert.equal(summary.counts['source/built'], 1);
  assert.deepEqual(summary.unsaved, [{ formula: 'php@8.6', key: 'exact-key', error: 'Connection timed out' }]);
});
