const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const root = 'downloaded-evidence';
const repo = process.env.GITHUB_REPOSITORY;
const run = process.env.GITHUB_RUN_ID;
const api = route => JSON.parse(cp.execFileSync('gh', ['api', route], {encoding: 'utf8'}));
cp.execFileSync('gh', ['run', 'download', run, '--repo', repo, '--dir', root], {stdio: 'inherit'});
const jobs = api(`repos/${repo}/actions/runs/${run}/jobs?per_page=100`).jobs;
const results = [];
for (const dir of fs.readdirSync(root)) {
  const match = /^(layouts|real)-(ubuntu-24.04|windows-latest|macos-latest)(?:-phpunit-(\d+))?$/.exec(dir);
  assert.ok(match, dir);
  const [, kind, os, major] = match;
  const name = kind === 'layouts' ? `Layouts (${os})` : `PHPUnit ${major} (${os})`;
  const job = jobs.find(x => x.name === name);
  assert.equal(job?.conclusion, 'success', name);
  const expected = fs.readdirSync(path.join(root, dir)).filter(x => x.endsWith('-expected.json'))
    .flatMap(file => JSON.parse(fs.readFileSync(path.join(root, dir, file))));
  const annotations = api(`repos/${repo}/check-runs/${job.id}/annotations?per_page=100`);
  const actual = annotations.filter(x => x.annotation_level !== 'notice').map(x => ({
    message: x.message, severity: x.annotation_level,
    file: x.path === '.github' ? null : x.path,
    line: x.path === '.github' ? null : x.start_line
  }));
  const sort = items => items.map(x => JSON.stringify(x)).sort();
  assert.deepEqual(sort(actual), sort(expected), name);
  const install = JSON.parse(fs.readFileSync(path.join(root, dir, 'install.json')));
  assert.equal(install.sha, process.env.EXPECTED_ACTION_SHA);
  results.push({name, url: job.html_url, annotations: actual.length, result: 'pass'});
  console.log(`${name}: exact annotation count, messages, severity, source locations and removal passed (${actual.length} annotations).`);
}
assert.equal(results.length, 12);
fs.writeFileSync('verified-results.json', JSON.stringify(results, null, 2));
fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `All 12 jobs passed exact annotation verification.\n\n${results.map(x => `- ${x.name}: ${x.annotations} correct annotations`).join('\n')}\n`);
