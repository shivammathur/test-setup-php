const fs = require('node:fs');
const path = require('node:path');
const {download, key, validateEntry} = require('./scripts/installer/install-extensions.cjs');
(async () => {
 const manifestFile = path.join(process.env.RUNNER_TEMP, 'extension-manifest.json');
 await download('extensions-8.5-manifest.json', manifestFile);
 const entries = JSON.parse(fs.readFileSync(manifestFile)).assets.filter(e => e.architecture === process.env.ARCH);
 require('node:assert/strict').equal(entries.length, 12);
 await Promise.all(entries.map(async entry => {
  validateEntry(entry);
  const directory = path.join('builds/extensions', 'extension-' + key(entry));
  fs.mkdirSync(directory, {recursive:true});
  fs.writeFileSync(path.join(directory, key(entry) + '.json'), JSON.stringify(entry));
  await download(entry.file, path.join(directory, entry.file), {sha256:entry.sha256, bytes:entry.bytes});
 }));
 fs.writeFileSync('extension-entries.json', JSON.stringify(entries));
})().catch(error => {console.error(error); process.exitCode=1;});
