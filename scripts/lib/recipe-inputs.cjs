const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {createHash} = require('node:crypto');
const memo = new Map();
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

function recipeInputs(file, mode = 'platforms') {
  if (!['platforms', 'source'].includes(mode)) throw new Error('Invalid recipe input projection');
  const raw = digest(fs.readFileSync(file)), key = `${file}:${mode}:${raw}`;
  if (!memo.has(key)) {
    const result = spawnSync('bash', [path.join(__dirname, '../build/formula-build-inputs.sh'), file, mode], {encoding: 'utf8'});
    if (result.error || result.status !== 0) throw result.error || new Error(result.stderr);
    memo.set(key, digest(result.stdout));
  }
  return memo.get(key);
}

function recipeCurrent(record, repository) {
  if (!record || !repository || typeof record.path !== 'string' || !record.path || record.path.includes('..') || path.isAbsolute(record.path)) return false;
  const file = path.join(repository, record.path);
  if (!fs.existsSync(file)) return false;
  if (digest(fs.readFileSync(file)) === record.sha256) return true;
  return record.inputs_schema === 1 && /^[a-f0-9]{64}$/.test(record.inputs_sha256 || '') &&
    recipeInputs(file, record.inputs_mode) === record.inputs_sha256;
}
module.exports = {recipeInputs, recipeCurrent};
