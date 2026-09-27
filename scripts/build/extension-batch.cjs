const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { key } = require('../installer/install-extensions.cjs');
const { variants, archiveEntries, verifyArchive } = require('../release/extension-batches.cjs');

function execute(program, args, env) {
  const result = spawnSync(program, args, { stdio: 'inherit', env });
  if (result.error || result.status !== 0) throw result.error || new Error(`${program} failed (${result.status})`);
}
function batch(entries, mode, { run = execute, output = 'builds/extensions', indexOutput = 'builds/index' } = {}) {
  if (!['build', 'test'].includes(mode)) throw new Error('Invalid batch mode');
  const failures = [], index = [];
  let corePinned = process.env.PHP_DARWIN_CORE_PREPARED === process.env.HOMEBREW_CORE_COMMIT &&
    /^[a-f0-9]{40}$/.test(process.env.HOMEBREW_CORE_COMMIT || '');
  for (const variant of variants(entries)) {
    const env = { ...process.env, PHP_VERSION: variant.php_version, ARCH: variant.architecture,
      BUILD: variant.build, TS: variant.thread_safety };
    // Preparation writes the nightly source commit for subsequent commands.
    // Each runtime gets its own environment; stable PHP must not inherit it.
    delete env.PHP_DARWIN_PHP_SRC_COMMIT;
    env.GITHUB_ENV = path.join(process.env.RUNNER_TEMP, `extension-${variant.php_version}-${variant.build}-${variant.thread_safety}.env`);
    fs.writeFileSync(env.GITHUB_ENV, '');
    console.log(`::group::Prepare PHP ${variant.php_version} ${variant.build}/${variant.thread_safety}`);
    try {
      run('bash', ['scripts/build/prepare-extension-pack.sh', mode], env);
      for (const line of fs.readFileSync(env.GITHUB_ENV, 'utf8').split('\n')) {
        const match = /^(PHP_DARWIN_PHP_SRC_COMMIT)=([a-f0-9]{40})$/.exec(line);
        if (match) env[match[1]] = match[2];
      }
      if (mode === 'build' && !corePinned) {
        run('bash', ['scripts/build/pin-core.sh'], env);
        corePinned = true;
      }
    } catch (error) {
      failures.push(...variant.entries.map(entry => key(entry)));
      console.error(error);
      console.log('::endgroup::');
      continue;
    }
    console.log('::endgroup::');
    for (const entry of variant.entries) {
      const identity = key(entry);
      console.log(`::group::${mode} ${identity}`);
      try {
        let directory;
        if (mode === 'build') {
          directory = path.resolve(output, `extension-${identity}`);
          fs.mkdirSync(directory, { recursive: true });
          run(process.execPath, ['.github/actions/source-cache/main.cjs'], { ...env, INPUT_STAGE: 'extensions',
            EXTENSION_PACK: entry.name, EXTENSION_PACK_OUTPUT: directory });
        } else {
          const matches = archiveEntries(output, [identity]).filter(item => key(item.entry) === identity);
          if (matches.length !== 1) throw new Error(`Missing or duplicate test archive: ${identity}`);
          directory = matches[0].directory;
          // Never leave an older producer report behind if this check fails.
          fs.rmSync(path.join(directory, 'validation.txt'), { force: true });
        }
        run(process.execPath, ['scripts/tests/native/extension-pack.test.cjs'], { ...env,
          EXTENSION_PACK: entry.name, EXTENSION_PACK_OUTPUT: directory });
        index.push(verifyArchive(directory, entry).entry);
      } catch (error) {
        console.error(error);
        failures.push(identity);
      }
      console.log('::endgroup::');
      // Checkpoint after every passing pack, even if another variant later fails.
      if (mode === 'build') {
        fs.mkdirSync(indexOutput, { recursive: true });
        fs.writeFileSync(path.join(indexOutput, 'entries.json'), JSON.stringify(index));
      }
    }
  }
  if (failures.length) throw new Error(`Failed ${mode} variants: ${failures.join(', ')}`);
}
module.exports = { batch };
if (require.main === module) {
  try { batch(JSON.parse(process.env.EXTENSION_ENTRIES), process.argv[2]); }
  catch (error) { console.error(error); process.exitCode = 1; }
}
