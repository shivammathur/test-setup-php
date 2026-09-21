const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const assert = require('assert/strict');
const yaml = require(path.join(process.cwd(), 'node_modules/js-yaml'));
const steps = yaml.load(fs.readFileSync('.github/workflows/publish.yml', 'utf8')).jobs.build.steps;
const selector = steps.find(step => step.id === 'publish-tag').run;
const publisher = steps.find(step => step.name === (process.env.TEST_REGISTRY === 'npm' ? 'Publish to NPM' : 'Publish to GitHub Packages')).run;
const evidence = path.join(process.env.GITHUB_WORKSPACE, 'evidence');
fs.mkdirSync(evidence, {recursive:true});
const results = [];
for (const [version, tag, expected] of [
  ['2.40.0-alpha.1', '2.40.0-alpha.1', 'next'],
  ['2.40.0-beta', '2.40.0-beta', 'next'],
  ['2.40.0-RC1', 'v2.40.0-RC1', 'next'],
  ['2.40.0', '2.40.0', 'latest']
]) {
  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  pkg.version = version;
  fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
  const eventTag = expected === 'next' ? '2.40.0' : '2.40.0-beta';
  const payload = process.env.TEST_EVENT === 'release' ? {release:{tag_name:eventTag}} : {inputs:{tag:eventTag}};
  const eventFile = path.join(evidence, `${version}-event.json`);
  const outputFile = path.join(evidence, `${version}-output.txt`);
  fs.writeFileSync(eventFile, JSON.stringify(payload));
  fs.writeFileSync(outputFile, '');
  cp.execFileSync('bash', ['-e', '-c', selector], {env:{...process.env,GITHUB_EVENT_PATH:eventFile,GITHUB_OUTPUT:outputFile}});
  const output = fs.readFileSync(outputFile, 'utf8').trim();
  assert.equal(output, `tag=${expected}`);
  const command = publisher.replace('${{ steps.publish-tag.outputs.tag }}', expected) + ' --dry-run --ignore-scripts --json';
  const json = cp.execFileSync('bash', ['-e','-c',command], {encoding:'utf8',env:{...process.env,NPM_CONFIG_DRY_RUN:'true'},stdio:['ignore','pipe','inherit']});
  fs.writeFileSync(path.join(evidence, `${version}-publish.json`), json);
  let result = JSON.parse(json);
  if (Array.isArray(result)) result = result[0];
  if (!result.files) result = Object.values(result).find(value => value && value.files);
  assert.equal(result.version, version);
  assert.equal(result.name, process.env.TEST_REGISTRY === 'npm' ? 'setup-php' : '@shivammathur/setup-php');
  const files = new Set(result.files.map(file => file.path));
  for (const file of ['lib/install.js','src/scripts/win32.ps1','src/scripts/extensions/add_extensions.ps1','src/configs/tools.json']) assert(files.has(file), file);
  results.push({event:process.env.TEST_EVENT,eventTag,name:result.name,version,channel:expected,files:result.entryCount,dryRun:true});
  console.log(`${process.env.TEST_EVENT}: package ${version}, event tag ${eventTag} -> ${expected}, ${result.name}, ${result.entryCount} files`);
}
fs.writeFileSync(path.join(evidence, 'summary.json'), JSON.stringify(results, null, 2));
