const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { identity, stageCheckpoint, restoreCheckpoint, restoreEarly } = require('../../cache/archive-checkpoint.cjs');
const { ReleaseCache } = require('../../cache/source-bottle-releases.cjs');

async function main(stage) {
  const inputs = { schema: 1, php: '0.0', arch: 'x86_64', build: 'release', ts: 'nts',
    revision: process.env.GITHUB_SHA, phpCommit: 'a'.repeat(40), extensionsCommit: 'b'.repeat(40),
    coreCommit: 'c'.repeat(40), platform: {fixture: true},
    packages: [{ fixture: process.env.GITHUB_RUN_ID }] };
  const item = identity(inputs);
  const root = path.join(process.env.RUNNER_TEMP, 'checkpoint-transfer-fixture');
  if (stage === 'stage') {
    const builds = path.join(root, 'builds');
    const upload = path.join(root, 'upload');
    fs.mkdirSync(builds, { recursive: true });
    const content = Buffer.from('native artifact transfer fixture\n');
    fs.writeFileSync(path.join(builds, item.archive), content);
    fs.writeFileSync(path.join(builds, item.archive + '.sha256'), crypto.createHash('sha256').update(content).digest('hex') + '  ' + item.archive + '\n');
    fs.writeFileSync(path.join(builds, item.metadata), JSON.stringify({ archive: item.archive,
      php_version: inputs.php, build: inputs.build, thread_safety: inputs.ts, architecture: inputs.arch,
      homebrew_php_commit: inputs.phpCommit, homebrew_extensions_commit: inputs.extensionsCommit }));
    stageCheckpoint(inputs, builds, upload);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `name=${item.name}\npath=${upload}\n`);
  } else if (stage === 'restore') {
    const cache = new ReleaseCache();
    const result = await restoreCheckpoint(cache, inputs, path.join(root, 'restored'));
    assert.equal(result.hit, true, 'the uploaded checkpoint was not restored');
    assert.equal(result.current, true);
    const early = await restoreEarly(cache, inputs, path.join(root, 'restored-early'));
    assert.equal(early.hit, true, 'this run should restore without installed PHP or dependencies');
    assert.equal(early.current, true);
    cache.request = async () => { throw new TypeError('Simulated Node connection failure'); };
    const fallback = await restoreCheckpoint(cache, inputs, path.join(root, 'restored-curl'));
    assert.equal(fallback.hit, true);
    assert.equal(cache.useFallback, true);
    console.log('GitHub artifact checkpoint round-trip passed with digest and input verification');
  } else throw new Error('Invalid checkpoint transfer test stage');
}
main(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1; });
