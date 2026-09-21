const fs = require('fs');
const assert = require('assert/strict');
let result = JSON.parse(fs.readFileSync(`${process.env.GITHUB_WORKSPACE}/evidence/publish.json`, 'utf8'));
if (Array.isArray(result)) result = result[0];
if (!result.files) result = Object.values(result).find(value => value && value.files);
assert(result, 'Missing package contents in publish dry run');
assert.equal(result.version, process.env.TEST_VERSION);
assert.equal(result.name, process.env.TEST_REGISTRY === 'npm' ? 'setup-php' : '@shivammathur/setup-php');
assert.equal(process.env.SELECTED_TAG, process.env.EXPECTED_TAG);
const files = new Set(result.files.map(file => file.path));
for (const name of ['lib/install.js', 'src/scripts/win32.ps1', 'src/scripts/extensions/add_extensions.ps1', 'src/configs/tools.json']) {
  assert(files.has(name), `Package is missing ${name}`);
}
const evidence = {name:result.name, version:result.version, tag:process.env.SELECTED_TAG, files:result.entryCount, bytes:result.size, dryRun:true};
fs.writeFileSync(`${process.env.GITHUB_WORKSPACE}/evidence/summary.json`, JSON.stringify(evidence, null, 2));
console.log(evidence);
