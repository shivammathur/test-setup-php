const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const expected = JSON.parse(fs.readFileSync('.e2e/manifest.json', 'utf8'));
for (const [filename, hash] of Object.entries(expected.files)) {
  const binary = path.join(process.env.CACHE_DIR, filename);
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(binary)).digest('hex'), hash, binary);
  console.log(`Restored binary matches seed: ${filename}`);
}
