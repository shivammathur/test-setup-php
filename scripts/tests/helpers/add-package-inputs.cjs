// Attach realistic dependency provenance to release fixtures. Tests can mutate
// the recorded recipe independently of PHP/coverage-extension source hashes.
const fs = require('node:fs');
const path = require('node:path');
const {digest} = require('../../installer/install-extensions.cjs');
const [manifestPath, repository] = process.argv.slice(2);
const relative = 'Abstract/abstract-php-extension.rb';
const manifest = JSON.parse(fs.readFileSync(manifestPath));
for (const asset of manifest.assets) asset.build_inputs = {schema: 1,
  source_records: [{repository: 'shivammathur/homebrew-extensions', path: relative,
    sha256: digest(fs.readFileSync(path.join(repository, relative)))}]};
fs.writeFileSync(manifestPath, JSON.stringify(manifest));
