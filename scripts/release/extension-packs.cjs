const fs = require('node:fs');
const path = require('node:path');
const { command, digest, key, validateEntry, origins } = require('../installer/install-extensions.cjs');
const configuration = require('../../conf/extension-packs.json');
const platforms = require('../../conf/platforms.json');
const { buildMatrix, testMatrix } = require('./extension-batches.cjs');
const { retention } = require('./extension-retention.cjs');
const { recipeCurrent } = require('../lib/recipe-inputs.cjs');
const { command: transferCommand, retryPolicy, httpError, githubJSON, workflowJobs, transfers } = require('./extension-transfers.cjs');
const root = path.resolve(__dirname, '../..');

function versionBatches(value = configuration.versions.join(' ')) {
  const versions = [...new Set(value.trim().split(/\s+/))];
  if (versions.some(version => !configuration.versions.includes(version))) throw new Error('Unsupported PHP version');
  // All fourteen versions now fit in 28 build and 42 compatibility jobs.
  return [versions];
}
async function dispatch({ versions = process.env.PHP_VERSIONS || undefined, afterRun = process.env.AFTER_RUN,
  repository = process.env.GITHUB_REPOSITORY || 'shivammathur/php-darwin', ref = process.env.GITHUB_REF_NAME || 'main',
  run = command, wait = ms => new Promise(resolve => setTimeout(resolve, ms)), now = Date.now } = {}) {
  if (repository !== 'shivammathur/php-darwin') throw new Error('Unexpected extension cache repository');
  const batches = versionBatches(versions);
  if (afterRun) {
    if (!/^[1-9][0-9]*$/.test(afterRun) || afterRun === process.env.GITHUB_RUN_ID) throw new Error('Invalid prerequisite run');
    const started = now();
    console.log(`Waiting for successful workflow run ${afterRun}`);
    while (true) {
      const result = JSON.parse(run('gh', ['api', `repos/${repository}/actions/runs/${afterRun}`]));
      if (result.status === 'completed') {
        if (result.conclusion !== 'success') throw new Error(`Prerequisite run ${afterRun} concluded ${result.conclusion}`);
        break;
      }
      if (now() - started >= 5 * 60 * 60 * 1000) throw new Error('Prerequisite run did not finish within five hours');
      await wait(60000);
    }
  }
  for (const batch of batches) {
    run('gh', ['workflow', 'run', 'cache-extensions.yml', '--repo', repository, '--ref', ref,
      '-f', `php-versions=${batch.join(' ')}`, '-f', 'builds=debug release', '-f', 'ts=nts zts', '-f', 'publish=true'], { inherit: true });
    console.log(`Dispatched optional extension caches for PHP ${batch.join(', ')}`);
  }
}
function freshnessReason(entry, repositories, phpManifest) {
  try {
    validateEntry(entry);
    const phpVersion = phpManifest.php_src_commit ? entry.php_semver?.split('-')[0] : entry.php_semver;
    if (phpVersion !== phpManifest.php_semver ||
        (phpManifest.php_src_commit || '') !== (entry.php_src_commit || '')) return 'PHP release changed';
    if (!entry.source_records?.length) return 'missing recipe records';
    for (const record of entry.source_records) {
      const repository = repositories[record.repository];
      if (!repository || !record.path || record.path.includes('..') || path.isAbsolute(record.path)) return 'invalid recipe record';
      if (!recipeCurrent(record, repository)) {
        return `recipe changed: ${record.repository}/${record.path}`;
      }
    }
    return null;
  } catch { return 'invalid published metadata'; }
}
function unchanged(entry, repositories, phpManifest) {
  return freshnessReason(entry, repositories, phpManifest) === null;
}
async function readManifest(version, retry = retryPolicy()) {
  return retry(`Read PHP ${version} extension manifest`, async () => {
    const response = await fetch(`${origins[0]}/extensions-${version}-manifest.json`, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 404) return { schema: 1, assets: [] };
      throw httpError(response.status, 'Read extension manifest');
    }
    const manifest = await response.json();
    if (manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid published extension manifest');
    manifest.assets.forEach(validateEntry);
    return manifest;
  });
}
async function readPHPManifest(version, retry) {
  return retry(`Read published PHP ${version}`, async () => {
    const response = await fetch(`https://github.com/shivammathur/php-darwin/releases/download/php-${version}/php-${version}-manifest.json`,
      { signal: AbortSignal.timeout(15000), cache: 'no-store' });
    if (!response.ok) {
      await response.body?.cancel();
      throw httpError(response.status, `Read published PHP ${version} manifest`);
    }
    const manifest = await response.json();
    if (manifest.schema !== 1 || manifest.php_version !== version || !manifest.php_semver || !Array.isArray(manifest.assets)) {
      throw new Error(`Invalid published PHP ${version} manifest`);
    }
    return manifest;
  });
}
async function validatePublishedPHP(entries, retry = retryPolicy()) {
  for (const version of new Set(entries.map(entry => entry.php_version))) {
    const manifest = await readPHPManifest(version, retry);
    for (const entry of entries.filter(entry => entry.php_version === version)) {
      const semver = manifest.php_src_commit ? entry.php_semver?.split('-')[0] : entry.php_semver;
      if (semver !== manifest.php_semver || (entry.php_src_commit || '') !== (manifest.php_src_commit || '') ||
          !manifest.assets.some(asset => asset.architecture === entry.architecture && asset.build === entry.build &&
            asset.thread_safety === entry.thread_safety)) {
        throw new Error(`Published PHP ${version} no longer matches ${key(entry)}; refusing stale extension publication`);
      }
    }
  }
}
async function plan() {
  const versions = (process.env.PHP_VERSIONS || '8.4').split(/\s+/);
  const selectedPacks = (process.env.EXTENSION_PACKS || Object.keys(configuration.packs).join(' ')).split(/\s+/);
  const builds = (process.env.BUILDS || 'release').split(/\s+/);
  const modes = (process.env.THREAD_SAFETY || 'nts').split(/\s+/);
  const repositories = { 'shivammathur/homebrew-extensions': path.resolve('homebrew-extensions'), 'Homebrew/homebrew-core': path.resolve('homebrew-core') };
  const include = [], reused = [], selected = [];
  const retry = retryPolicy();
  const recovery = new Map();
  const resumeRuns = (process.env.RESUME_RUNS || '').trim().split(/\s+/).filter(Boolean);
  // Explicit recovery keeps completed artifacts even if orchestration changed.
  // Sources are ordered oldest to newest; the latest successful pack wins.
  for (const id of resumeRuns) {
    const recovered = await require('./extension-recovery.cjs').planRecovery(id);
    for (const entry of recovered.entries) recovery.set(key(entry), entry);
  }
  for (const php_version of versions) {
    if (!configuration.versions.includes(php_version)) throw new Error('Unsupported PHP version');
    const existing = await readManifest(php_version, retry);
    const phpManifest = await readPHPManifest(php_version, retry);
    for (const name of selectedPacks) for (const build of builds) for (const thread_safety of modes) for (const architecture of Object.keys(platforms)) {
      if (!Object.hasOwn(configuration.packs, name)) throw new Error('Unknown extension pack');
      const context = { name, php_version, build, thread_safety, architecture };
      const identity = key(context);
      if (!phpManifest.assets.some(asset => asset.build === build && asset.thread_safety === thread_safety && asset.architecture === architecture)) {
        throw new Error(`Published PHP cache variant is unavailable: ${identity}`);
      }
      const previous = existing.assets.find(asset => key(asset) === identity);
      if (recovery.has(identity)) {
        reused.push(recovery.get(identity)); selected.push(context); continue;
      }
      // Resume fills holes in the requested release, without rebuilding already
      // published packs. Normal scheduled runs still apply full freshness checks.
      if (resumeRuns.length && previous && previous.php_semver?.split('-')[0] === phpManifest.php_semver?.split('-')[0] &&
          (previous.php_src_commit || '') === (phpManifest.php_src_commit || '')) continue;
      const reason = process.env.FORCE === 'true' ? 'forced rebuild' :
        previous ? freshnessReason(previous, repositories, phpManifest) : 'not published';
      if (!reason) continue;
      console.log(`Selected ${identity}: ${reason}`);
      include.push({ ...context, runner: platforms[architecture].build_runner });
      selected.push(context);
    }
  }
  const buildsMatrix = buildMatrix(include), reuseMatrix = buildMatrix(reused), tests = testMatrix(selected);
  if ([buildsMatrix, reuseMatrix, tests].some(matrix => matrix.include.length > 256)) throw new Error('Extension matrix exceeds Actions limit');
  const result = JSON.stringify(buildsMatrix);
  console.log(result);
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT,
    `matrix=${result}\ncount=${include.length}\nreuse=${JSON.stringify(reuseMatrix)}\nreuse-count=${reused.length}\n` +
    `selected-count=${selected.length}\nkeys=${JSON.stringify(selected.map(key))}\ntests=${JSON.stringify(tests)}\n`);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `${reused.length} completed packs reused on Ubuntu; ${include.length} missing/changed packs in ${buildsMatrix.include.length} native build jobs; ` +
    `${tests.include.length} compatibility jobs, grouped by PHP version and runner.\n`);
}
function compatibilityMatrix(entries) {
  return testMatrix(entries);
}
function scan(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(item => {
    const file = path.join(directory, item.name);
    return item.isDirectory() ? scan(file) : [file];
  });
}
async function validatePublishRun(id, run = transferCommand, retry = retryPolicy()) {
  if (!/^[1-9][0-9]*$/.test(id || '')) throw new Error('Invalid source workflow run');
  const route = `repos/shivammathur/php-darwin/actions/runs/${id}`;
  const source = await githubJSON(route, { run, retry });
  const recovery = source.path === '.github/workflows/recover-extensions.yml';
  if (source.status !== 'completed' || source.head_branch !== 'main' ||
      source.head_repository?.full_name !== 'shivammathur/php-darwin' ||
      (!recovery && source.path !== '.github/workflows/cache-extensions.yml')) throw new Error('Untrusted extension source run');
  const jobs = await workflowJobs(route, source.run_attempt, { run, retry });
  if (recovery) {
    const plan = jobs.find(job => job.name === 'plan');
    const reuse = jobs.filter(job => job.name.startsWith('reuse ('));
    const tests = jobs.filter(job => /^Test PHP /.test(job.name) && job.conclusion !== 'skipped');
    const publication = jobs.find(job => job.name === 'publish');
    if (!plan || !reuse.length || [plan, ...reuse, ...tests].some(job => job.status !== 'completed' || job.conclusion !== 'success') ||
        !publication?.steps?.some(step => step.name === 'Verify the publication contains exactly the tested variants' && step.conclusion === 'success')) {
      throw new Error('Source recovery plan, archive reuse, compatibility and exact publication selection must pass');
    }
    console.log(`Validated recovery run ${id}: ${reuse.length} archive groups; retained compatibility evidence and exact publication selection passed`);
    return;
  }
  const builds = jobs.filter(job => /^(?:(imagick|mongodb|memcached) \/ PHP |Cache PHP |Reuse PHP )/.test(job.name) && job.conclusion !== 'skipped');
  const tests = jobs.filter(job => /^Test PHP /.test(job.name));
  if (!builds.length || !tests.length || [...builds, ...tests].some(job => job.status !== 'completed' || job.conclusion !== 'success')) {
    throw new Error('Source extension builds and compatibility tests must all pass');
  }
  console.log(`Validated source run ${id}: ${builds.length} builds and ${tests.length} compatibility jobs`);
}
async function publish(directory, { run = transferCommand, retry = retryPolicy() } = {}) {
  const entries = scan(directory).filter(file => file.endsWith('.json')).map(file => {
    const entry = validateEntry(JSON.parse(fs.readFileSync(file)));
    const archive = path.join(path.dirname(file), entry.file);
    const bytes = fs.readFileSync(archive);
    if (digest(bytes) !== entry.sha256 || bytes.length !== entry.bytes) throw new Error('Invalid extension publish artifact');
    const report = JSON.parse(fs.readFileSync(path.join(path.dirname(file), 'validation.txt')));
    if (report.name !== entry.name || report.sha256 !== entry.sha256 || !Number.isFinite(report.install_seconds) ||
        report.install_seconds < 0 || !report.php_preserved || !report.services_preserved) throw new Error('Extension validation did not pass');
    return { entry, archive };
  });
  if (new Set(entries.map(({ entry }) => key(entry))).size !== entries.length) throw new Error('Invalid extension publish batch');
  // Recovery may outlive a PHP release or nightly API update. Reject its stale
  // packs before uploads, even when their earlier compatibility reports passed.
  await validatePublishedPHP(entries.map(({ entry }) => entry), retry);
  const repo = 'shivammathur/php-darwin';
  const release = 'extensions';
  const env = { ...process.env, AWS_ACCESS_KEY_ID: process.env.CF_R2_AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: process.env.CF_R2_AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION: 'auto',
    AWS_EC2_METADATA_DISABLED: 'true', AWS_MAX_ATTEMPTS: '1', AWS_REQUEST_CHECKSUM_CALCULATION: 'when_required',
    AWS_RESPONSE_CHECKSUM_VALIDATION: 'when_required' };
  if (!env.AWS_ACCESS_KEY_ID || !env.AWS_SECRET_ACCESS_KEY || !process.env.CF_R2_AWS_S3_ENDPOINT) throw new Error('Cloudflare credentials are required');
  const response = await retry('Inspect extension release', async () => {
    const result = await fetch(`https://api.github.com/repos/${repo}/releases/tags/${release}`, {
      headers: { Authorization: `Bearer ${process.env.GH_TOKEN}`, 'X-GitHub-Api-Version': '2022-11-28' },
      signal: AbortSignal.timeout(15000),
    });
    await result.body?.cancel();
    if (!result.ok && result.status !== 404) throw httpError(result.status, 'Inspect extension release');
    return result;
  });
  if (response.status === 404 && entries.length) {
    await retry('Create extension release', () => run('gh', ['release', 'create', release, '--repo', repo,
      '--title', 'Optional PHP extension caches', '--notes', '', '--latest=false']));
  } else if (!response.ok) throw new Error(`Cannot inspect extension release: HTTP ${response.status}`);
  const staging = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP || '/tmp', 'extension-release-'));
  const transfer = transfers({ directory: staging, env, endpoint: process.env.CF_R2_AWS_S3_ENDPOINT, run, retry });
  const cleanup = retention({ env, endpoint: process.env.CF_R2_AWS_S3_ENDPOINT, run, retry });
  const incoming = entries.map(({ entry }) => entry.file);
  const publishedVersions = [], failedVersions = [];
  let failure;
  try {
    if (entries.length) await cleanup.capacity([...incoming,
      ...new Set(entries.map(({ entry }) => `extensions-${entry.php_version}-manifest.json`)), 'install-extensions.cjs']);
    // Commit each PHP-version manifest only after every referenced archive is
    // uploaded and verified. A failure in another version must not
    // discard that progress. Permanent validation/authentication failures stop.
    for (const version of new Set(entries.map(({ entry }) => entry.php_version))) {
      try {
        const selected = entries.filter(({ entry }) => entry.php_version === version);
        for (const { archive } of selected) {
          await transfer.github(archive, true);
          await transfer.mirror(archive, true);
        }
        const previous = await readManifest(version, retry);
        const merged = new Map(previous.assets.map(entry => [key(entry), entry]));
        for (const { entry } of selected) merged.set(key(entry), entry);
        const manifest = path.join(staging, `extensions-${version}-manifest.json`);
        fs.writeFileSync(manifest, JSON.stringify({ schema: 1, assets: [...merged.values()].sort((a, b) => key(a).localeCompare(key(b))) }, null, 2) + '\n');
        // Recheck after transfers in case PHP changed while immutable archives
        // were uploading. Keep those archives available for recovery.
        await validatePublishedPHP(selected.map(({ entry }) => entry), retry);
        await transfer.mirror(manifest, false);
        await transfer.github(manifest, false);
        publishedVersions.push(version);
        try { await cleanup.prune(incoming, version); }
        catch (error) {
          cleanup.report.warnings.push(error.message);
          console.warn(`Published PHP ${version}; retention will resume next time: ${error.message}`);
        }
      } catch (error) {
        failedVersions.push({ php_version: version, error: error.message });
        console.error(`PHP ${version} publication incomplete; continuing independent versions: ${error.message}`);
      }
    }
    if (failedVersions.length) throw new Error(`Publication incomplete: ${failedVersions.map(item => `PHP ${item.php_version}: ${item.error}`).join('; ')}`);
    const installer = path.join(root, 'scripts/installer/install-extensions.cjs');
    await transfer.mirror(installer, false);
    await transfer.github(installer, false);
    if (!entries.length) {
      try { await cleanup.prune(); }
      catch (error) {
        cleanup.report.warnings.push(error.message);
        console.warn(`Installer published; retention deferred: ${error.message}`);
      }
    }
  } catch (error) { failure = error.message; throw error; }
  finally {
    const report = { ...transfer.report, retention: cleanup.report, archives: entries.length, published_versions: publishedVersions,
      remaining_versions: [...new Set(entries.map(({ entry }) => entry.php_version))].filter(version => !publishedVersions.includes(version)),
      failed_versions: failedVersions, success: !failure, ...(failure ? { failure } : {}) };
    // Individual read records are logged above and retained in the artifact;
    // avoid duplicating hundreds of them into one oversized summary log line.
    console.log(`Extension publication: ${JSON.stringify({ ...report, reads: undefined })}`);
    if (process.env.EXTENSION_PUBLISH_REPORT) fs.writeFileSync(process.env.EXTENSION_PUBLISH_REPORT, JSON.stringify(report, null, 2) + '\n');
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `Extension publication ${failure ? 'failed' : 'succeeded'}. ${report.archives} validated archives.\n\n` +
      `GitHub: ${report.github_reused} reused, ${report.github_uploaded} uploaded. ` +
      `Cloudflare: ${report.cloudflare_reused} reused, ${report.cloudflare_uploaded} uploaded.\n\n` +
      `Published PHP versions: ${publishedVersions.join(', ') || 'none'}.\n\n` +
      (failure ? 'Rerun the failed publish job to resume verified transfers; passing build and test jobs do not need to run again.\n' : ''));
    fs.rmSync(staging, { recursive: true, force: true });
  }
}
module.exports = { unchanged, freshnessReason, readManifest, plan, publish, compatibilityMatrix, versionBatches, dispatch, validatePublishRun, validatePublishedPHP };
if (require.main === module) (async () => {
  if (process.argv[2] === 'dispatch') await dispatch();
  else if (process.argv[2] === 'plan') await plan();
  else if (process.argv[2] === 'publish') await publish(process.argv[3]);
  else if (process.argv[2] === 'validate-publish-run') await validatePublishRun(process.argv[3]);
  else throw new Error('Usage: extension-packs.cjs plan|publish|dispatch|validate-publish-run');
})().catch(error => { console.error(error); process.exitCode = 1; });
