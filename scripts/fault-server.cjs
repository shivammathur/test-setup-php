const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const root = path.resolve('evidence');
fs.mkdirSync(root, {recursive: true});
const server = http.createServer((req, res) => {
  fs.appendFileSync(path.join(root, 'faults.jsonl'), JSON.stringify({url: req.url, status: 503}) + '\n');
  res.writeHead(503, {'Content-Type': 'text/plain'});
  res.end('Injected metadata outage');
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(root, 'fault-port'), String(server.address().port)));
