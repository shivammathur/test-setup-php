const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = 'downloaded-evidence';
const repo = process.env.GITHUB_REPOSITORY;
const run = process.env.GITHUB_RUN_ID;
const api = route => JSON.parse(cp.execFileSync('gh', ['api', route], {encoding: 'utf8'}));
cp.execFileSync('gh', ['run', 'download', run, '--repo', repo, '--dir', root], {stdio: 'inherit'});
const jobs = api(`repos/${repo}/actions/runs/${run}/jobs?per_page=100`).jobs;
const results = [];
const allAnnotations = [];
for (const dir of fs.readdirSync(root)) {
  const folder = path.join(root, dir);
  const install = JSON.parse(fs.readFileSync(path.join(folder, 'install.json')));
  const job = jobs.find(x => x.name === install.jobName);
  assert.equal(job?.conclusion, 'success', install.jobName);
  assert.equal(install.sha, process.env.EXPECTED_ACTION_SHA);
  const matcher = fs.readFileSync(path.join(folder, 'phpunit.json'));
  assert.equal(crypto.createHash('sha256').update(matcher).digest('hex'), install.matcherSha256);
  const expected = fs.readdirSync(folder).filter(x => x.endsWith('-expected.json'))
    .flatMap(file => JSON.parse(fs.readFileSync(path.join(folder, file))));
  const annotations = JSON.parse(cp.execFileSync('gh', ['api', '--paginate', '--slurp', `repos/${repo}/check-runs/${job.id}/annotations?per_page=100`], {encoding: 'utf8'})).flat();
  const actual = annotations.filter(x => !(x.annotation_level === 'notice' && x.path === '.github' && x.start_line === 1 && x.message === 'Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.')).map(x => ({
    message: x.message, severity: x.annotation_level,
    file: x.path === '.github' ? null : x.path,
    line: x.path === '.github' ? null : x.start_line
  }));
  const sort = items => items.map(x => JSON.stringify(x)).sort();
  assert.deepEqual(sort(actual), sort(expected), install.jobName);
  results.push({name: install.jobName, url: job.html_url, annotations: actual.length, result: 'pass'});
  allAnnotations.push({name: install.jobName, annotations});
  console.log(`${install.jobName}: ${actual.length} exact annotation messages, severities and locations verified, including removal.`);
}
assert.equal(results.length, 30);
fs.writeFileSync('verified-results.json', JSON.stringify(results, null, 2));
fs.writeFileSync('all-annotations.json', JSON.stringify(allAnnotations, null, 2));
fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `All 30 jobs passed exact annotation verification.\n\n${results.map(x => `- ${x.name}: ${x.annotations} annotations`).join('\n')}\n`);
