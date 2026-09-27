const fs = require('node:fs');
const path = require('node:path');
const { ReleaseCache } = require('../cache/source-bottle-releases.cjs');

function seconds(start, end) {
  if (!start || !end) return null;
  const value = (Date.parse(end) - Date.parse(start)) / 1000;
  return Number.isFinite(value) && value >= 0 ? value : null;
}
function duration(value) {
  if (value === null || value === undefined) return 'unavailable';
  const rounded = Math.round(value);
  return `${Math.floor(rounded / 60)}m ${rounded % 60}s`;
}
function summarizeEvents(events) {
  const counts = {};
  const phases = { prefetchMs: 0, compileMs: 0, bottleMs: 0, uploadMs: 0, waitedMs: 0 };
  for (const event of events) {
    const name = `${event.kind}/${event.result}`;
    counts[name] = (counts[name] || 0) + 1;
    if (event.kind === 'prefetch') phases.prefetchMs += event.elapsedMs || 0;
    for (const key of Object.keys(phases)) phases[key] += event[key] || 0;
  }
  const unsaved = events.filter(event => event.kind === 'source' && event.result === 'built' && event.saved === false)
    .map(({ formula, key, saveError }) => ({ formula, key, error: saveError || 'Upload did not complete' }));
  return { counts, phases, unsaved };
}
function summarizeWorkflow(run, jobs, now) {
  const attempt = run.run_attempt || 1;
  return { run: run.id, attempt, revision: run.head_sha, event: run.event, measuredAt: now,
    elapsedThroughReportSeconds: seconds(attempt > 1 ? run.run_started_at : run.created_at, now),
    jobs: jobs.map(job => ({ id: job.id, name: job.name, conclusion: job.conclusion,
      queueSeconds: seconds(job.created_at, job.started_at), runSeconds: seconds(job.started_at, job.completed_at),
      steps: (job.steps || []).map(step => ({ name: step.name, conclusion: step.conclusion,
        seconds: seconds(step.started_at, step.completed_at) })) })) };
}
function eventsForAttempt(events, run, attempt) {
  return events.filter(event => String(event.run) === String(run) && String(event.attempt) === String(attempt));
}
function eventsAt(directory) {
  if (!directory || !fs.existsSync(directory)) return [];
  if (fs.statSync(directory).isFile()) return fs.readFileSync(directory, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line));
  return fs.readdirSync(directory).flatMap(name => eventsAt(path.join(directory, name)));
}
function eventTable(events) {
  const summary = summarizeEvents(events);
  const rows = Object.entries(summary.counts).map(([name, count]) => `| ${name} | ${count} |`);
  return ['### Work performed', '', '| Result | Packages / archives |', '|---|---:|', ...rows, '',
    ...(summary.unsaved.length ? [`**${summary.unsaved.length} compiled source bottles were not saved to the release cache.**`, '',
      ...summary.unsaved.map(item => `- ${item.formula}: ${item.error} (key ${item.key}).`), ''] : []),
    `Upstream bottle prefetch: **${duration(summary.phases.prefetchMs / 1000)}**; source compilation: **${duration(summary.phases.compileMs / 1000)}**; bottle creation/post-install: **${duration(summary.phases.bottleMs / 1000)}**; source-cache uploads: **${duration(summary.phases.uploadMs / 1000)}**; ownership waits: **${duration(summary.phases.waitedMs / 1000)}**.`, '',
    'These phase totals are accumulated work across jobs; they are not workflow elapsed time.', '',
    ...events.filter(event => event.missReason || event.reason).map(event =>
      `- ${event.formula || `${event.php} ${event.arch} ${event.build}/${event.ts}`}: ${event.missReason || event.reason} (key ${event.key?.slice(-12) || 'unavailable'}).`), ''].join('\n');
}
async function main(mode) {
  let markdown;
  let events;
  if (mode === 'local') {
    events = eventsAt(process.env.PHP_DARWIN_METRICS);
    markdown = eventTable(events);
  } else if (mode === 'workflow') {
    const cache = new ReleaseCache();
    const runId = process.env.GITHUB_RUN_ID;
    const attempt = process.env.GITHUB_RUN_ATTEMPT;
    if (!/^[1-9]\d*$/.test(runId || '') || !/^[1-9]\d*$/.test(attempt || '')) throw new Error('Invalid report run ID/attempt');
    const run = await cache.api(`actions/runs/${runId}/attempts/${attempt}`);
    const jobs = [];
    for (let page = 1; ; page++) {
      const result = await cache.api(`actions/runs/${runId}/attempts/${attempt}/jobs?per_page=100&page=${page}`);
      jobs.push(...result.jobs);
      if (result.jobs.length < 100) break;
    }
    // A partial rerun keeps timing artifacts from successful earlier jobs.
    // Count only work performed in this attempt, without double-counting it.
    events = eventsForAttempt(eventsAt(path.join(process.env.GITHUB_WORKSPACE, '.timing')), runId, attempt);
    const report = { ...summarizeWorkflow(run, jobs, new Date().toISOString()), work: summarizeEvents(events), events };
    fs.writeFileSync('workflow-performance.json', JSON.stringify(report, null, 2) + '\n');
    markdown = ['## Workflow performance', '',
      `Elapsed from ${report.attempt > 1 ? `attempt ${report.attempt} start` : 'dispatch'} through this report: **${duration(report.elapsedThroughReportSeconds)}**.`, '',
      '| Job | Runner queue | Execution | Result |', '|---|---:|---:|---|',
      ...report.jobs.map(job => `| ${job.name} | ${duration(job.queueSeconds)} | ${duration(job.runSeconds)} | ${job.conclusion || 'running'} |`), '',
      'Queue and execution times are shown separately. Parallel job durations must not be added to estimate elapsed time.', '',
      '### Build stages', '', '| Job | PHP installation | Extensions | Packaging |', '|---|---:|---:|---:|',
      ...report.jobs.filter(job => /(^| \/ )Build PHP /.test(job.name)).map(job => {
        const sum = pattern => job.steps.filter(step => pattern.test(step.name)).reduce((total, step) => total + (step.seconds || 0), 0);
        return `| ${job.name} | ${duration(sum(/^Install .* PHP formula$/))} | ${duration(sum(/^Cache .* coverage extensions$/))} | ${duration(sum(/^Package .* Homebrew cache$/))} |`;
      }), '', eventTable(events)].join('\n');
  } else throw new Error('Invalid performance report mode');
  const unsaved = summarizeEvents(events).unsaved.length;
  if (unsaved) console.warn(`::warning::${unsaved} compiled source bottles were not saved to the release cache; see the performance report.`);
  console.log(markdown);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown + '\n');
}
if (require.main === module) main(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { seconds, duration, summarizeEvents, summarizeWorkflow, eventsForAttempt };
