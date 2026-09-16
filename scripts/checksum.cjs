const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execSync, execFileSync} = require('node:child_process');
const composerVersion = execSync('composer --no-ansi --version', {encoding: 'utf8'});
if (!composerVersion.includes('Composer version 2.9.8')) throw new Error(`Wrong Composer version: ${composerVersion}`);
if (process.argv[2] === 'verify' && (process.env.METADATA_OUTCOME !== 'failure' || process.env.PRERELEASE_OUTCOME !== 'failure')) throw new Error('A checksum mismatch was accepted');
const dir = process.platform === 'win32' ? process.env.TEMP : path.join(process.env.RUNNER_TOOL_CACHE, 'setup-php', 'tools');
const versions = ['2.9.8+build.1', '2.9.8-rc.1'];
const evidence = [];
for (const version of versions) {
  const url = `https://github.com/composer/composer/releases/download/${version}/composer.phar`;
  let key = crypto.createHash('sha256').update(url).digest('hex').slice(0, 16);
  if (process.platform === 'win32') key = key.toUpperCase();
  const file = path.join(dir, `composer-${key}`);
  if (process.argv[2] === 'seed') {
    fs.mkdirSync(dir, {recursive: true});
    const fixture = 'Intentionally invalid Composer checksum fixture';
    if (process.platform === 'win32') {
      fs.writeFileSync(file, fixture);
    } else {
      execFileSync('sudo', ['tee', file], {input: fixture, stdio: ['pipe', 'ignore', 'inherit']});
    }
  } else if (fs.existsSync(file)) {
    throw new Error(`Checksum rejection did not evict ${file}`);
  }
  evidence.push({version, url, file, evicted: !fs.existsSync(file)});
}
fs.mkdirSync('evidence', {recursive: true});
fs.writeFileSync(`evidence/checksums-${process.argv[2]}.json`, JSON.stringify(evidence, null, 2));

fs.writeFileSync(`evidence/composer-${process.argv[2]}.txt`, composerVersion);
console.log(JSON.stringify(evidence, null, 2));
