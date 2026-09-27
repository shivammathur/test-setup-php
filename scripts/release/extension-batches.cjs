const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { key, validateContext, validateEntry, digest, command } = require('../installer/install-extensions.cjs');
const platforms = require('../../conf/platforms.json');

function buildMatrix(entries) {
  const groups = new Map();
  for (const entry of entries) {
    key(entry);
    const identity = `${entry.php_version}-${entry.architecture}`;
    if (!groups.has(identity)) groups.set(identity, { php_version: entry.php_version, architecture: entry.architecture,
      runner: platforms[entry.architecture].build_runner, entries: [] });
    groups.get(identity).entries.push(entry);
  }
  return { include: [...groups.values()] };
}
function testMatrix(entries) {
  return { include: buildMatrix(entries).include.flatMap(group =>
    platforms[group.architecture].test_runners.filter(runner => runner !== group.runner && runner !== 'macos-latest')
      .map(runner => ({ ...group, runner }))) };
}
function variants(entries) {
  const groups = new Map();
  for (const entry of entries) {
    key(entry);
    const identity = [entry.php_version, entry.architecture, entry.build, entry.thread_safety].join('-');
    if (!groups.has(identity)) groups.set(identity, { ...validateContext(entry), entries: [] });
    groups.get(identity).entries.push(entry);
  }
  return [...groups.values()];
}
function archiveEntries(root, identities) {
  if (!fs.existsSync(root)) return [];
  return fs.readdirSync(root, { withFileTypes: true }).flatMap(item => {
    const file = path.join(root, item.name);
    if (item.isDirectory()) return archiveEntries(file, identities);
    return item.name.endsWith('.json') && (!identities || identities.includes(item.name.slice(0, -5))) ?
      [{ entry: validateEntry(JSON.parse(fs.readFileSync(file))), directory: root }] : [];
  });
}
function verifyArchive(directory, expected) {
  const matches = archiveEntries(directory, [key(expected)]).filter(item => key(item.entry) === key(expected));
  if (matches.length !== 1) throw new Error(`Missing or duplicate archive: ${key(expected)}`);
  const { entry, directory: folder } = matches[0];
  if ((expected.sha256 && expected.sha256 !== entry.sha256) || (expected.bytes && expected.bytes !== entry.bytes)) {
    throw new Error(`Archive differs from the recovery index: ${key(entry)}`);
  }
  const archive = path.join(folder, entry.file), bytes = fs.readFileSync(archive);
  if (digest(bytes) !== entry.sha256 || bytes.length !== entry.bytes) throw new Error(`Invalid archive bytes: ${key(entry)}`);
  const report = JSON.parse(fs.readFileSync(path.join(folder, 'validation.txt')));
  if (report.name !== entry.name || report.sha256 !== entry.sha256 || !Number.isFinite(report.install_seconds) ||
      report.install_seconds < 0 || !report.php_preserved || !report.services_preserved) throw new Error(`Invalid native report: ${key(entry)}`);
  return { entry, directory: folder };
}
function downloadArtifact(artifact, directory, { run = spawnSync,
  wait = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) } = {}) {
  if (!Number.isSafeInteger(artifact.artifact_id) || artifact.artifact_id < 1) throw new Error('Invalid artifact ID');
  fs.mkdirSync(directory, { recursive: true });
  const zip = path.join(directory, 'artifact.zip');
  for (let attempt = 1; ; attempt++) {
    try {
      const fd = fs.openSync(zip, 'w');
      let result;
      try {
        result = run('gh', ['api', `repos/shivammathur/php-darwin/actions/artifacts/${artifact.artifact_id}/zip`],
          { stdio: ['ignore', fd, 'pipe'], encoding: 'utf8', timeout: 180000 });
      } finally { fs.closeSync(fd); }
      if (result.error || result.status !== 0) throw result.error || new Error(`Artifact ${artifact.artifact_id}: ${result.stderr}`);
      if (artifact.artifact_digest && `sha256:${digest(fs.readFileSync(zip))}` !== artifact.artifact_digest) throw new Error('Artifact digest mismatch');
      break;
    } catch (error) {
      fs.rmSync(zip, { force: true });
      if (attempt === 3) throw error;
      console.warn(`Artifact ${artifact.artifact_id} transfer failed; retry ${attempt + 1}/3: ${error.message}`);
      wait(1000 * 2 ** (attempt - 1));
    }
  }
  // Artifacts are selected only from this repository's completed main workflows.
  const members = command('unzip', ['-Z1', zip]).split('\n');
  if (members.some(member => member.startsWith('/') || member.split('/').includes('..'))) throw new Error('Unsafe artifact path');
  command('unzip', ['-q', zip, '-d', directory]);
  fs.rmSync(zip);
}
function reuse(entries, output, { download = downloadArtifact } = {}) {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'extension-reuse-'));
  const downloaded = new Map();
  const index = [];
  try {
    for (const expected of entries) {
      const id = expected.artifact_id;
      if (!downloaded.has(id)) {
        const folder = path.join(temporary, String(id));
        download(expected, folder);
        downloaded.set(id, folder);
      }
      const { entry, directory } = verifyArchive(downloaded.get(id), expected);
      const destination = path.join(output, `extension-${key(entry)}`);
      fs.mkdirSync(destination, { recursive: true });
      for (const name of [entry.file, `${key(entry)}.json`, 'validation.txt']) fs.copyFileSync(path.join(directory, name), path.join(destination, name));
      index.push(entry);
      console.log(`Reused ${key(entry)} from run ${expected.source_run}, artifact ${id}; SHA256 ${entry.sha256}`);
    }
    return index;
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
}
module.exports = { buildMatrix, testMatrix, variants, archiveEntries, verifyArchive, downloadArtifact, reuse };
if (require.main === module) {
  try {
    if (process.argv[2] !== 'reuse') throw new Error('Usage: extension-batches.cjs reuse');
    const index = reuse(JSON.parse(process.env.EXTENSION_ENTRIES), 'builds/extensions');
    fs.mkdirSync('builds/index', { recursive: true });
    fs.writeFileSync('builds/index/entries.json', JSON.stringify(index));
  } catch (error) { console.error(error); process.exitCode = 1; }
}
