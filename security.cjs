const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = path.resolve(process.env.ACTION_ROOT || 'action-under-test');
const bundle = path.join(root, 'dist/index.js');
const tests = [
  ['input', '$0'],
  ['plain', ';id'],
  ['plain', '$$'],
  ['plain', '`w`'],
  ['asdf', "8.4';echo COMPROMISED > e2e-pwned;#"],
  ['lock', '8.4$(echo COMPROMISED > e2e-pwned)'],
  ['json', '8.4`echo COMPROMISED > e2e-pwned`'],
  ['json', '8.4\n;echo COMPROMISED > e2e-pwned'],
  ['lock', 8.4],
  ['json', ['8.4']],
  ['lock-subdir', '8.4|echo COMPROMISED > e2e-pwned'],
  ['custom', '8.4&echo COMPROMISED > e2e-pwned'],
  ['plain', 'php\n8.4'],
  ['plain', 'php 8.4 8.5'],
  ['plain', '# comment only\n'],
  ['missing', ''],
  ['manifest', '8.4$(echo COMPROMISED > e2e-pwned)'],
  ['manifest', '8.4\n'],
  ['manifest', 'pre'],
  ['manifest', '8.4.2'],
  ['manifest', 8.4],
  ['manifest', ['8.4']],
  ['manifest', null]
];
const results = [];
for (const [source, value] of tests) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-php-negative-'));
  const env = {...process.env};
  for (const key of Object.keys(env)) {
    if (/^(INPUT_|PHP[-_]VERSION|COMPOSER_PROJECT_DIR$|EXTENSIONS$|TOOLS$|COVERAGE$|INI[-_]|VERBOSE$)/i.test(key)) delete env[key];
  }
  env.INPUT_TOOLS = 'none';
  const put = (name, text) => { const file = path.join(cwd, name); fs.mkdirSync(path.dirname(file), {recursive: true}); fs.writeFileSync(file, text); };
  let expected = 'Invalid PHP version';
  const args = [];
  switch (source) {
    case 'input': env['INPUT_PHP-VERSION'] = value; expected += ' in php-version input'; break;
    case 'plain': put('.php-version', value); expected += ' in .php-version'; break;
    case 'asdf': env['INPUT_PHP-VERSION-FILE'] = '.tool-versions'; put('.tool-versions', `ruby 3.3.0\nphp ${value}\nnode 24.0.0`); expected += ' in .tool-versions'; break;
    case 'custom': env['INPUT_PHP-VERSION-FILE'] = 'version config/php version'; put(env['INPUT_PHP-VERSION-FILE'], value); expected += ' in version config/php version'; break;
    case 'lock': put('composer.lock', JSON.stringify({'platform-overrides': {php: value}})); expected += ' in composer.lock platform-overrides.php'; break;
    case 'json': put('composer.json', JSON.stringify({config: {platform: {php: value}}})); expected += ' in composer.json config.platform.php'; break;
    case 'lock-subdir': env.COMPOSER_PROJECT_DIR = 'composer project'; put('composer project/composer.lock', JSON.stringify({'platform-overrides': {php: value}})); expected += ' in composer.lock platform-overrides.php'; break;
    case 'missing': env['INPUT_PHP-VERSION-FILE'] = 'missing-version'; expected = "Could not find 'missing-version' file."; break;
    case 'manifest': put('.php-version', 'latest'); env.E2E_MANIFEST = JSON.stringify(value); args.push('--require', path.join(__dirname, 'manifest-preload.cjs')); expected += ' in manifest'; break;
  }
  const child = spawnSync(process.execPath, [...args, bundle], {cwd, env, encoding: 'utf8', timeout: 20000});
  const output = (child.stdout || '') + (child.stderr || '');
  assert.equal(child.error, undefined, `${source}: child failed: ${child.error}`);
  assert.equal(child.status, 1, `${source}: expected rejection, got ${child.status}: ${output}`);
  assert.ok(output.includes(expected), `${source}: wrong error: ${output}`);
  for (const filename of ['run.sh', 'run.ps1']) assert.equal(fs.existsSync(path.join(root, 'src/scripts', filename)), false, `${source}: setup script was generated`);
  assert.equal(fs.existsSync(path.join(cwd, 'e2e-pwned')), false, `${source}: payload executed`);
  results.push({source, value, result: 'rejected before script generation'});
  console.log(`PASS ${source}: ${JSON.stringify(value)}`);
}
fs.writeFileSync('security-result.json', JSON.stringify({os: process.platform, cases: results}, null, 2));
if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Validated ${results.length} distinct rejection cases against the committed bundle on ${process.platform}; no setup script or payload marker was created.\n`);
