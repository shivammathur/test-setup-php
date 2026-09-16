const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
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
    fs.writeFileSync(file, 'Intentionally invalid Composer checksum fixture');
  } else if (fs.existsSync(file)) {
    throw new Error(`Checksum rejection did not evict ${file}`);
  }
  evidence.push({version, url, file, evicted: !fs.existsSync(file)});
}
fs.mkdirSync('evidence', {recursive: true});
fs.writeFileSync(`evidence/checksums-${process.argv[2]}.json`, JSON.stringify(evidence, null, 2));
