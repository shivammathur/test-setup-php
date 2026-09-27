const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {current} = require('../../build/package-inputs.cjs');
const {recipeInputs} = require('../../lib/recipe-inputs.cjs');
const {digest} = require('../../installer/install-extensions.cjs');

test('dependency changes invalidate packages; php-darwin revisions and unrelated bottles retain cache hits', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'package-inputs-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const file = path.join(root, 'formula.rb');
  const recipe = 'class Fixture < Formula\n  url "https://example.invalid/lib-1.tar.gz"\n  bottle do\n' +
    `    sha256 arm64_sonoma: "${'a'.repeat(64)}"\n    sha256 arm64_linux: "${'b'.repeat(64)}"\n  end\nend\n`;
  fs.writeFileSync(file, recipe);
  const record = {repository: 'Homebrew/homebrew-core', path: 'formula.rb', sha256: digest(recipe),
    inputs_schema: 1, inputs_mode: 'platforms', inputs_sha256: recipeInputs(file)};
  const inputs = {schema: 1, builder_sha256: 'a'.repeat(64), source_records: [record]};
  const manifest = {assets: [{build_inputs: inputs}]}, repositories = {'Homebrew/homebrew-core': root};
  assert.equal(current(manifest, repositories), true);
  fs.writeFileSync(file, recipe.replace('b'.repeat(64), 'c'.repeat(64)));
  assert.equal(current(manifest, repositories), true);
  fs.writeFileSync(file, recipe.replace('a'.repeat(64), 'd'.repeat(64)));
  assert.equal(current(manifest, repositories), false);
  fs.writeFileSync(file, recipe.replace('lib-1', 'lib-2'));
  assert.equal(current(manifest, repositories), false);
  fs.writeFileSync(file, recipe);
  inputs.builder_sha256 = 'f'.repeat(64);
  assert.equal(current(manifest, repositories), true);
  delete inputs.builder_sha256;
  assert.equal(current(manifest, repositories), true);
  assert.equal(current({assets: [{}]}, repositories), false);
  delete inputs.source_records;
  assert.equal(current(manifest, repositories), false);
});
