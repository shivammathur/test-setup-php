const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = 'C:\\tools\\php';
function pdbInfo(file) {
  const pdb = fs.readFileSync(file);
  if (!pdb.subarray(0, 24).toString('ascii').startsWith('Microsoft C/C++ MSF 7.00')) throw new Error(`Invalid PDB: ${file}`);
  const blockSize = pdb.readUInt32LE(32);
  const directorySize = pdb.readUInt32LE(44);
  const blockMap = pdb.readUInt32LE(52) * blockSize;
  const directoryBlocks = Math.ceil(directorySize / blockSize);
  const chunks = [];
  for (let i = 0; i < directoryBlocks; i++) {
    const offset = pdb.readUInt32LE(blockMap + i * 4) * blockSize;
    chunks.push(pdb.subarray(offset, offset + blockSize));
  }
  const directory = Buffer.concat(chunks).subarray(0, directorySize);
  const streams = directory.readUInt32LE(0);
  let cursor = 4 + streams * 4;
  for (let stream = 0; stream < streams; stream++) {
    const size = directory.readUInt32LE(4 + stream * 4);
    if (size === 0xffffffff) continue;
    const count = Math.ceil(size / blockSize);
    if (stream === 1) {
      const chunks = [];
      for (let i = 0; i < count; i++) {
        const offset = directory.readUInt32LE(cursor + i * 4) * blockSize;
        chunks.push(pdb.subarray(offset, offset + blockSize));
      }
      const info = Buffer.concat(chunks).subarray(0, size);
      return {guid: info.subarray(12, 28).toString('hex'), age: info.readUInt32LE(8), size: pdb.length};
    }
    cursor += count * 4;
  }
  throw new Error(`PDB information stream missing: ${file}`);
}
const php = path.join(root, 'php.exe');
const actual = execFileSync(php, ['-r', 'echo PHP_VERSION;'], {encoding: 'utf8'}).trim();
if (!actual.startsWith(process.env.PHP_VERSION + '.')) throw new Error(`Wrong PHP version: ${actual}`);
const binaries = ['php.exe', process.env.PHPTS === 'ts' ? 'php8ts.dll' : 'php8.dll'];
const evidence = [];
for (const binary of binaries) {
  const pe = fs.readFileSync(path.join(root, binary));
  const rsds = pe.indexOf('RSDS');
  if (rsds < 0) throw new Error(`CodeView record missing: ${binary}`);
  const guid = pe.subarray(rsds + 4, rsds + 20).toString('hex');
  const age = pe.readUInt32LE(rsds + 20);
  const end = pe.indexOf(0, rsds + 24);
  const name = path.win32.basename(pe.subarray(rsds + 24, end).toString('utf8'));
  const pdb = path.join(root, name);
  const info = pdbInfo(pdb);
  if (info.guid !== guid || info.age !== age) throw new Error(`PDB does not match ${binary}: ${JSON.stringify({guid, age, info})}`);
  evidence.push({binary, pdb, php: actual, guid, age, size: info.size});
}
const faults = fs.readFileSync('evidence/faults.jsonl', 'utf8').trim().split('\n').map(JSON.parse);
if (!faults.some(x => x.url === '/manifest.json')) throw new Error('Manifest outage was not exercised');
if (process.env.DISCOVERY === 'html' && !faults.some(x => x.url === '/api')) throw new Error('API outage was not exercised');
fs.writeFileSync('evidence/pdb-matches.json', JSON.stringify(evidence, null, 2));
console.log(JSON.stringify(evidence, null, 2));
