const fs = require('node:fs');
const http = require('node:http');
const archive = fs.readFileSync(process.argv[2]);
const log = process.argv[3];
const server = http.createServer((req, res) => {
  fs.appendFileSync(log, `${req.url}\n`);
  if (req.url === '/http-error') {
    res.writeHead(503);
    res.end('unavailable');
    return;
  }
  res.writeHead(200, {'Content-Length': archive.length + (req.url === '/late-error' ? 100 : 0), 'Connection': 'close'});
  if (req.url === '/truncated') {
    res.end(archive.subarray(0, Math.floor(archive.length / 2)));
  } else if (req.url === '/corrupt') {
    const broken = Buffer.from(archive);
    broken[broken.length - 1] ^= 255;
    res.end(broken);
  } else {
    res.end(archive);
  }
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(`${log}.port`, String(server.address().port)));
