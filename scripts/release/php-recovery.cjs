const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {githubJSON, workflowJobs} = require('./extension-transfers.cjs');
const {downloadArtifact} = require('./extension-batches.cjs');

function validate(source, jobs, artifacts, plan, version, repository = 'shivammathur/php-darwin') {
  if (source.status !== 'completed' || source.head_branch !== 'main' || source.head_repository?.full_name !== repository ||
      !['.github/workflows/cache-stable.yml', '.github/workflows/cache-nightly.yml'].includes(source.path) ||
      !/^[a-f0-9]{40}$/.test(source.head_sha || '')) throw new Error('Untrusted or unfinished PHP source run');
  if (plan.schema !== 1 || plan.php_version !== version || plan.revision !== source.head_sha ||
      !Array.isArray(plan.builds) || !plan.builds.length || !Array.isArray(plan.tests) || !plan.tests.length) {
    throw new Error('Missing or mismatched PHP build plan');
  }
  const successful = suffix => {
    const matches = jobs.filter(job => job.name === suffix || job.name.endsWith(' / ' + suffix));
    return matches.length === 1 && matches[0].status === 'completed' && matches[0].conclusion === 'success';
  };
  const selected = [];
  for (const {arch, build, ts} of plan.builds) {
    if (!['arm64', 'x86_64'].includes(arch) || !['release', 'debug'].includes(build) || !['nts', 'zts'].includes(ts)) throw new Error('Invalid PHP build variant');
    const name = `${arch} / Build PHP ${version} ${build}/${ts} package on ${arch}`;
    if (!successful(name)) throw new Error(`Unsuccessful or missing build: ${name}`);
    const prefix = `php-${version}-${arch}-${build}-${ts}-`;
    const matches = artifacts.filter(item => !item.expired && item.name.startsWith(prefix) && /^[a-f0-9]{64}$/.test(item.name.slice(prefix.length)));
    if (matches.length !== 1 || !/^sha256:[a-f0-9]{64}$/.test(matches[0].digest || '')) throw new Error(`Missing or ambiguous verified archive: ${prefix}`);
    selected.push(matches[0]);
  }
  if (new Set(selected.map(item => item.id)).size !== selected.length) throw new Error('Duplicate build plan variants');
  for (const {arch, runner} of plan.tests) {
    if (!plan.builds.some(item => item.arch === arch) || typeof runner !== 'string' ||
        !successful(`${arch} / Test PHP ${version} packages on ${runner}`)) throw new Error(`Unsuccessful or missing compatibility test: ${arch}/${runner}`);
  }
  for (const arch of new Set(plan.builds.map(item => item.arch))) {
    if (plan.builds.filter(item => item.arch === arch).length !== 4 || !plan.tests.some(item => item.arch === arch)) {
      throw new Error(`Incomplete publish matrix for ${arch}`);
    }
  }
  return selected;
}

async function inspect(id, version, {read = githubJSON, jobsFor = workflowJobs, download = downloadArtifact} = {}) {
  if (!/^[1-9][0-9]*$/.test(id || '') || !/^(5\.6|7\.[0-4]|8\.[0-7])$/.test(version || '')) throw new Error('Invalid PHP recovery inputs');
  const repo = 'shivammathur/php-darwin', route = `repos/${repo}/actions/runs/${id}`;
  const source = await read(route);
  // Check provenance before downloading any artifact from the source workflow.
  if (source.status !== 'completed' || source.head_branch !== 'main' || source.head_repository?.full_name !== repo ||
      !['.github/workflows/cache-stable.yml', '.github/workflows/cache-nightly.yml'].includes(source.path)) throw new Error('Untrusted or unfinished PHP source run');
  const jobs = await jobsFor(route, source.run_attempt);
  const artifacts = (await read(`${route}/artifacts?per_page=100`, {paginate: true})).flatMap(page => page.artifacts);
  const plans = artifacts.filter(item => !item.expired && item.name === `build-plan-${version}`);
  let plan;
  if (plans.length === 1 && /^sha256:[a-f0-9]{64}$/.test(plans[0].digest || '')) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'php-recovery-'));
    try {
      download({artifact_id: plans[0].id, artifact_digest: plans[0].digest}, directory);
      plan = JSON.parse(fs.readFileSync(path.join(directory, 'build-plan.json')));
    } finally { fs.rmSync(directory, {recursive: true, force: true}); }
  } else if (plans.length) throw new Error('Ambiguous or invalid PHP build plan artifact');
  else {
    // Older runs did not upload a plan. Reconstruct their complete variant and
    // runner requirements from their own checked-in configuration, never today's.
    const record = await read(`repos/${repo}/contents/conf/platforms.json?ref=${source.head_sha}`);
    const platforms = JSON.parse(Buffer.from(record.content, 'base64').toString());
    const arches = Object.keys(platforms).filter(arch => jobs.some(job =>
      job.name.includes(`${arch} / Build PHP ${version} `)));
    plan = {schema: 1, php_version: version, revision: source.head_sha,
      builds: arches.flatMap(arch => ['debug', 'release'].flatMap(build => ['nts', 'zts'].map(ts => ({arch, build, ts})))),
      tests: arches.flatMap(arch => platforms[arch].test_runners.map(runner => ({arch, runner})))};
  }
  return validate(source, jobs, artifacts, plan, version, repo);
}
module.exports = {validate, inspect};
if (require.main === module) inspect(process.argv[2], process.env.PHP_VERSION).then(artifacts => {
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `artifact-ids=${artifacts.map(item => item.id).join(',')}\n`);
  console.log(`Validated source workflow and ${artifacts.length} tested archive artifacts`);
}).catch(error => {console.error(error); process.exitCode = 1;});
