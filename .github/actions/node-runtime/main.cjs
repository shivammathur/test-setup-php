const fs = require('node:fs');

// Homebrew cleanup removes its Node formula. JavaScript actions use the
// runner's own runtime, whose absolute path survives that cleanup.
fs.appendFileSync(process.env.GITHUB_ENV, `PHP_DARWIN_NODE=${process.execPath}\n`);
