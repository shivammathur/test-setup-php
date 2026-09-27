const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function runSetupPhp(source, run = spawnSync) {
  // Stock setup-php replaces the first occurrence of "darwin" in its script
  // path. These runners live under ~/php-darwin. Execute identical action bytes
  // from a neutral directory; never patch the upstream action or runner files.
  const directory = fs.mkdtempSync('/tmp/php-cache-setup-');
  try {
    for (const name of ['dist', 'src']) fs.cpSync(path.join(source, name), path.join(directory, name), { recursive: true });
    // Some repository macOS labels use self-hosted machines. This fixture tests
    // the hosted-runner cache contract; stock setup-php intentionally bypasses
    // package caches when it detects a self-hosted environment.
    const env = { ...process.env, runner: 'github', RUNNER_ENVIRONMENT: 'github-hosted',
      ImageOS: process.env.ImageOS || 'macos15', ImageVersion: process.env.ImageVersion || 'php-darwin-e2e',
      ACT: '', CONTAINER: '' };
    const result = run(process.execPath, [path.join(directory, 'dist/index.js')], { stdio: 'inherit', env });
    if (result.error) throw result.error;
    return result.status ?? 1;
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

if (require.main === module) process.exitCode = runSetupPhp(process.argv[2]);
module.exports = { runSetupPhp };
