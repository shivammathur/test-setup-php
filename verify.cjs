const assert = require('node:assert/strict');
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const {createHash} = require('node:crypto');
const state = require('./e2e-state.json');
const php = code => execFileSync('php', ['-r', code], {encoding: 'utf8'}).trim();
const actual = php('echo PHP_VERSION;');
assert.equal(actual.split('.').slice(0, 2).join('.'), state.expected);
assert.equal(process.env.ACTION_VERSION, actual, 'php-version action output must match the installed runtime');
assert.equal(fs.existsSync('e2e-pwned'), false, 'Version-file content executed');
for (const [file, digest] of Object.entries(state.files)) {
  assert.equal(createHash('sha256').update(fs.readFileSync(file)).digest('hex'), digest, `${file} changed`);
}
assert.equal(php('echo ini_get("post_max_size");'), '256M');
assert.equal(php('echo ini_get("date.timezone");'), 'Asia/Kolkata');
if (state.test.source === 'smoke') {
  for (const extension of ['mbstring', 'xml', 'gd']) assert.equal(php(`echo extension_loaded('${extension}') ? 'yes' : 'no';`), 'yes');
  assert.match(execFileSync(process.platform === 'win32' ? 'composer.bat' : 'composer', ['--version'], {encoding: 'utf8', shell: process.platform === 'win32'}), /Composer version/);
  assert.equal(php('echo ini_get("error_log");'), '$(echo COMPROMISED > e2e-pwned)');
  assert.equal(fs.existsSync('e2e-pwned'), false, 'INI content executed');
}
const result = {case: state.test.id, os: process.platform, expected: state.expected, actual, output: process.env.ACTION_VERSION, result: 'pass'};
fs.writeFileSync('e2e-result.json', JSON.stringify(result, null, 2));
fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `| Case | Expected | Installed | Result |\n|---|---|---|---|\n| ${state.test.id} | ${state.expected} | ${actual} | pass |\n`);
console.log(JSON.stringify(result));
