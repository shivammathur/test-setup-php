const assert = require('node:assert/strict');
const fs = require('node:fs');

const api = 'https://api.github.com/repos/' + process.env.GITHUB_REPOSITORY;
const headers = {
  Authorization: 'Bearer ' + process.env.GITHUB_TOKEN,
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28'
};
const phases = ['lower', 'upper', 'debug-lower', 'debug-upper', 'reset'];
const report = [];

async function get(url, json = true) {
  const response = await fetch(url, {headers});
  if (!response.ok) throw new Error(response.status + ' fetching ' + url);
  return json ? response.json() : response.text();
}

(async () => {
  const data = await get(api + '/actions/runs/' + process.env.GITHUB_RUN_ID + '/jobs?per_page=100');
  const jobs = data.jobs.filter(job => /^(ubuntu-24\.04|macos-15|windows-2022) \/ /.test(job.name));
  assert.equal(jobs.length, 24, 'Expected all 24 matrix jobs');
  for (const job of jobs) {
    const entry = {job: job.name, id: job.id, conclusion: job.conclusion, cases: []};
    report.push(entry);
    try {
      assert.equal(job.conclusion, 'success', 'Matrix job failed');
      const text = (await get(api + '/actions/jobs/' + job.id + '/logs', false))
        .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '');
      const lines = text.split(/\r?\n/).map(line => line.replace(/^\d{4}-\d\d-\d\dT\S+\s+/, ''));
      const commands = [];
      for (let index = 0; index < lines.length; index++) {
        const line = lines[index];
        if (line.includes('[debug]') || line.startsWith('+') || line.startsWith('DEBUG:')) continue;
        const match = line.match(/\b(?:bash|pwsh)(?:\.exe)?\s+(.+[\\/]src(?:-verbose-[A-Za-z0-9]+)?[\\/]scripts[\\/]run\.(?:sh|ps1))\s*$/i);
        if (match) commands.push({index, path: match[1]});
      }
      assert.equal(commands.length, 5, 'Expected five real action executions');
      const mode = job.name.split(' / ')[1];
      const windows = job.name.startsWith('windows-');
      for (let i = 0; i < commands.length; i++) {
        const phase = phases[i];
        const expectedTrace = phase === 'reset' ? 0 : mode === 'vv' ? 1 : mode === 'vvv' ? 2 : 0;
        const enabled = phase !== 'reset' && (phase.startsWith('debug-') || ['true', 'v', 'vv', 'vvv'].includes(mode));
        const segment = lines.slice(commands[i].index + 1, commands[i + 1]?.index ?? lines.length);
        const traceLines = segment.filter(line => windows ? /^DEBUG:/.test(line) : /^\++\s/.test(line));
        const assignments = traceLines.filter(line => /^DEBUG:\s+!\s+SET\s/.test(line));
        assert.equal(commands[i].path.includes('src-verbose-'), enabled, phase + ': wrong script executed');
        assert.equal(traceLines.length > 0, expectedTrace > 0, phase + ': wrong tracing state');
        if (windows) assert.equal(assignments.length > 0, expectedTrace === 2, phase + ': wrong PowerShell trace level');
        entry.cases.push({phase, enabled, expectedTrace, executed: commands[i].path, traceLines: traceLines.length, assignments: assignments.length});
      }
    } catch (error) {
      entry.error = error.message;
      process.exitCode = 1;
    }
    console.log(JSON.stringify(entry));
  }
  fs.writeFileSync('log-results.json', JSON.stringify(report, null, 2));
  assert.equal(report.filter(row => row.error).length, 0, 'See log-results.json for failures');
  console.log('Verified all 120 action executions, covering 96 configurations and 24 quiet resets.');
})().catch(error => {
  fs.writeFileSync('log-results.json', JSON.stringify({error: error.message, jobs: report}, null, 2));
  console.error(error.message);
  process.exitCode = 1;
});
