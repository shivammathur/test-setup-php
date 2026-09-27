const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Readable } = require('node:stream');

function errorDetails(error) {
  const parts = [];
  for (let item = error; item && parts.length < 3; item = item.cause) {
    parts.push([item.code, item.message].filter(Boolean).join(': '));
  }
  return parts.join('; ').slice(0, 2000);
}

// A separate curl process avoids reusing Node HTTP connections after a long
// synchronous Homebrew build. Credentials stay in a private temporary config,
// never argv. curl strips Authorization on redirects to another origin.
async function curlRequest(url, { method = 'GET', headers = {}, body, signal } = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'php-darwin-http-'));
  const cleanup = () => fs.rmSync(temporary, { recursive: true, force: true });
  const config = path.join(temporary, 'request.conf');
  const headerFile = path.join(temporary, 'headers');
  const bodyFile = path.join(temporary, 'body');
  const quote = value => {
    if (/[\r\n\0]/.test(value)) throw new Error('Invalid HTTP request value');
    return '"' + value.replaceAll('\\', '\\\\').replaceAll('"', '\\"') + '"';
  };
  try {
    const lines = [`url = ${quote(url)}`];
    for (const [name, value] of new Headers(headers)) lines.push(`header = ${quote(`${name}: ${value}`)}`);
    fs.writeFileSync(config, lines.join('\n') + '\n', { mode: 0o600 });
    const args = ['--disable', '--config', config, '--silent', '--show-error', '--globoff',
      '--location', '--max-redirs', '5', '--connect-timeout', '30', '--compressed',
      '--proto', '=http,https', '--proto-redir', new URL(url).protocol === 'https:' ? '=https' : '=http,https',
      '--request', method, '--dump-header', headerFile, '--output', bodyFile, '--write-out', '%{http_code}'];
    if (body !== undefined) args.push('--data-binary', '@-');
    const { code, stdout, stderr } = await new Promise((resolve, reject) => {
      const child = spawn('curl', args, { signal, stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = '', stderr = '', failure;
      child.on('error', error => { failure = error; });
      child.stdout.on('data', data => { stdout = (stdout + data).slice(-100); });
      child.stderr.on('data', data => { stderr = (stderr + data).slice(-2000); });
      // A server can reject an upload before reading its whole body (422).
      child.stdin.on('error', () => {});
      const inputError = error => { failure = error; child.kill(); };
      if (body?.pipe) { body.once('error', inputError); body.pipe(child.stdin); }
      else child.stdin.end(body);
      child.on('close', code => {
        if (body?.pipe) { body.unpipe(child.stdin); body.off('error', inputError); }
        if (failure) reject(failure);
        else resolve({ code, stdout, stderr });
      });
    });
    fs.unlinkSync(config);
    if (code !== 0) {
      const error = new Error(`curl exit ${code}: ${stderr.trim()}`);
      error.retryable = true;
      throw error;
    }
    const status = Number(stdout);
    const block = fs.readFileSync(headerFile, 'utf8').split(/\r?\n\r?\n/)
      .filter(value => /^HTTP\/\S+ \d{3}/.test(value)).at(-1);
    fs.unlinkSync(headerFile);
    if (!block || !Number.isInteger(status) || status < 200 || status > 599) throw new Error('Invalid curl HTTP response');
    const responseHeaders = new Headers();
    for (const line of block.split(/\r?\n/).slice(1)) {
      const colon = line.indexOf(':');
      if (colon > 0) responseHeaders.append(line.slice(0, colon), line.slice(colon + 1).trim());
    }
    if (method === 'HEAD' || [204, 205, 304].includes(status)) {
      cleanup();
      return new Response(null, { status, headers: responseHeaders });
    }
    const stream = fs.createReadStream(bodyFile);
    stream.once('close', cleanup);
    return new Response(Readable.toWeb(stream), { status, headers: responseHeaders });
  } catch (error) { cleanup(); throw error; }
}

module.exports = { curlRequest, errorDetails };
