const fs = require('node:fs');
const path = require('node:path');
const {spawn} = require('node:child_process');
(async () => {
  fs.mkdirSync('evidence', {recursive: true});
  const fd = fs.openSync('evidence/server.log', 'a');
  const child = spawn(process.execPath, [path.resolve('scripts/fault-server.cjs')], {detached: true, stdio: ['ignore', fd, fd]});
  child.unref();
  for (let i = 0; !fs.existsSync('evidence/fault-port') && i < 100; i++) await new Promise(r => setTimeout(r, 50));
  const port = Number(fs.readFileSync('evidence/fault-port', 'utf8'));
  const file = 'action/src/scripts/win32.ps1';
  const original = fs.readFileSync(file, 'utf8');
  let source = original;
  const replace = (from, to) => {
    if (source.split(from).length !== 2) throw new Error(`Expected one endpoint: ${from}`);
    source = source.replace(from, to);
  };
  replace('"$php_builder/releases/download/php$version/manifest.json"', `"http://127.0.0.1:${port}/manifest.json"`);
  if (process.env.DISCOVERY === 'html') {
    replace('"https://api.github.com/repos/shivammathur/php-builder-windows/releases/tags/php$version"', `"http://127.0.0.1:${port}/api"`);
  }
  fs.writeFileSync(file, source);
  fs.writeFileSync('evidence/injected-endpoints.json', JSON.stringify({port, discovery: process.env.DISCOVERY, source: process.env.ACTION_SHA}, null, 2));
})().catch(e => { console.error(e); process.exitCode = 1; });
