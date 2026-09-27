#!/usr/bin/env node
// Standalone optional extension installer. No Homebrew operations or PHP installation.
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { pipeline } = require('node:stream/promises');
const { Readable } = require('node:stream');

const packs = { imagick: ['imagick'], mongodb: ['mongodb'], memcached: ['igbinary', 'msgpack', 'memcached'] };
const origins = ['https://github.com/shivammathur/php-darwin/releases/download/extensions',
  'https://artifacts.php-darwin.setup-php.com/extensions'];
const hex = /^[a-f0-9]{64}$/;
function command(program, args, options = {}) {
  const result = spawnSync(program, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw result.error || new Error(`${program} ${args.join(' ')} failed (${result.status}): ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function digest(data) { return crypto.createHash('sha256').update(data).digest('hex'); }
function safePath(value) {
  return typeof value === 'string' && value.length > 0 && !/[\x00-\x1f\x7f\\]/.test(value) &&
    !value.startsWith('/') && value.split('/').every(part => part && part !== '.' && part !== '..');
}
function validateContext(context) {
  if (!context || !/^(?:5\.6|7\.[0-4]|8\.[0-7])$/.test(context.php_version) ||
      !['arm64', 'x86_64'].includes(context.architecture) ||
      !['release', 'debug'].includes(context.build) || !['nts', 'zts'].includes(context.thread_safety)) {
    throw new Error('Unsupported extension cache configuration');
  }
  return context;
}
function key(entry) {
  validateContext(entry);
  if (!Object.hasOwn(packs, entry.name)) throw new Error('Unknown extension pack');
  return [entry.name, entry.php_version, entry.build, entry.thread_safety, entry.architecture].join('-');
}
function validateEntry(entry) {
  key(entry);
  if (entry.schema !== 1 || !hex.test(entry.sha256) || !hex.test(entry.inputs_sha256) ||
      !/^[0-9]{8}$/.test(entry.php_api) ||
      !Number.isInteger(entry.bytes) || entry.bytes < 1 || entry.bytes > 180000000 ||
      !Number.isInteger(entry.minimum_macos) || entry.minimum_macos < 14 ||
      entry.file !== `${key(entry)}-${entry.sha256}.tar.zst`) throw new Error('Invalid extension cache metadata');
  return entry;
}
async function download(name, destination, { sha256, bytes, bases = origins,
  fresh = false, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
  if (!safePath(name) || name.includes('/')) throw new Error('Invalid download name');
  let lastError;
  const missing = new Set();
  for (const base of bases) {
    const attempts = 3;
    for (let attempt = 1; attempt <= attempts; attempt++) {
      const temporary = `${destination}.partial`;
      try {
        missing.delete(base);
        // Give archives time to finish on either origin; metadata stays bounded.
        const response = await fetch(`${base}/${name}${fresh ? `?refresh=${Date.now()}` : ''}`, { signal: AbortSignal.timeout(bytes ? 300000 : 30000) });
        if (!response.ok || !response.body) {
          await response.body?.cancel();
          const retryAfter = response.headers.get('retry-after');
          if ([404, 410].includes(response.status)) missing.add(base);
          throw Object.assign(new Error(`HTTP ${response.status}`), {
            retryAfter: /^\d{1,6}$/.test(retryAfter || '') ? Math.min(30, Number(retryAfter)) : 0
          });
        }
        let received = 0;
        const hash = crypto.createHash('sha256');
        const limit = bytes || 2000000;
        await pipeline(Readable.fromWeb(response.body), async function* (source) {
          for await (const chunk of source) {
            received += chunk.length;
            if (received > limit) throw new Error('Download exceeds expected size');
            hash.update(chunk);
            yield chunk;
          }
        }, fs.createWriteStream(temporary, { flags: 'wx', mode: 0o600 }));
        if ((bytes && received !== bytes) || (sha256 && hash.digest('hex') !== sha256)) {
          throw new Error('Extension archive checksum/size mismatch');
        }
        await fsp.rename(temporary, destination);
        return;
      } catch (error) {
        lastError = error;
        await fsp.rm(temporary, { force: true });
        if (attempt === attempts) break;
        const delay = Math.max(attempt, error.retryAfter || 0);
        console.warn(`Extension download retry ${attempt + 1}/${attempts} in ${delay}s: ${error.message}`);
        await sleep(delay * 1000);
      }
    }
  }
  throw Object.assign(new Error(`Could not download ${name}: ${lastError.message}`), { retired: missing.size === bases.length });
}
async function prefetch(directory, context, requested, options = {}) {
  validateContext(context);
  const names = [...new Set(requested)];
  if (!names.length || names.some(name => !Object.hasOwn(packs, name))) throw new Error('Invalid requested extensions');
  await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
  const manifestPath = path.join(directory, 'manifest.json');
  await download(`extensions-${context.php_version}-manifest.json`, manifestPath, options);
  const manifest = JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
  if (manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid extension manifest');
  let refreshed;
  const select = (manifest, name) => {
    if (manifest.schema !== 1 || !Array.isArray(manifest.assets)) throw new Error('Invalid extension manifest');
    const candidates = manifest.assets.filter(entry => entry.name === name &&
      Object.entries(context).every(([field, value]) => entry[field] === value));
    if (candidates.length !== 1) throw new Error(`No unique compatible archive for ${name}`);
    return validateEntry(candidates[0]);
  };
  const results = await Promise.allSettled(names.map(async name => {
    let entry = select(manifest, name);
    console.log(`Downloading ${name} cache (${entry.bytes} bytes)`);
    try {
      await download(entry.file, path.join(directory, entry.file), { ...options, sha256: entry.sha256, bytes: entry.bytes });
    } catch (error) {
      if (!error.retired) throw error;
      // Publication can retire the archive after this install read its manifest.
      // Refresh once, shared across packs; retain exact context and checksums.
      refreshed ||= (async () => {
        await download(`extensions-${context.php_version}-manifest.json`, manifestPath, { ...options, fresh: true });
        return JSON.parse(await fsp.readFile(manifestPath, 'utf8'));
      })();
      const replacement = select(await refreshed, name);
      if (replacement.file === entry.file) throw error;
      entry = replacement;
      await download(entry.file, path.join(directory, entry.file), { ...options, sha256: entry.sha256, bytes: entry.bytes });
    }
    await fsp.writeFile(path.join(directory, `${name}.json`), JSON.stringify(entry));
    try {
      // Use independent processes so extraction cannot block other downloads.
      // This overlaps PHP setup without loading or changing the active PHP.
      await (options.prepare || prepareDownloaded)(directory, name);
    } catch (error) {
      await fsp.rm(path.join(directory, `${name}.json`), { force: true });
      throw error;
    }
    return name;
  }));
  results.forEach((result, index) => {
    if (result.status === 'rejected') console.warn(`Extension cache ${names[index]}: ${result.reason.message}`);
  });
  return results.filter(result => result.status === 'fulfilled').map(result => result.value);
}
// Keep the action's raw input opaque until it reaches the installer. Only
// unversioned pack requests are eligible; explicit disable/version/source
// requests for a pack or one of its serializers retain the caller's behavior.
function selectRequested(input) {
  const tokens = String(input).split(',').map(value => value.trim().toLowerCase().replace(/^(:)?php[-_]/, '$1'));
  return Object.entries(packs).filter(([name, modules]) => tokens.includes(name) &&
    !modules.some(module => tokens.some(token => token === `:${module}` ||
      token.startsWith(`${module}-`) || token.startsWith(`${module}@`))))
    .map(([name]) => name);
}
function requestedPacks(directory) {
  const names = fs.readFileSync(path.join(directory, 'requested.txt'), 'utf8').trim().split('\n').filter(Boolean);
  if (names.some(name => !Object.hasOwn(packs, name)) || new Set(names).size !== names.length) {
    throw new Error('Invalid requested extension packs');
  }
  return names;
}
function validateBase(entry, base) {
  validateContext(base);
  if (!['php_version', 'architecture', 'build', 'thread_safety'].every(field => entry[field] === base[field]) ||
      !entry.php_semver || !base.php_semver || entry.php_semver.replace(/-dev$/, '') !== base.php_semver.replace(/-dev$/, '') ||
      (entry.php_src_commit || '') !== (base.php_src_commit || '')) {
    throw new Error('Extension cache does not match the installed PHP release/source');
  }
}
function installDownloaded(directory, name) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [__filename, 'install', directory, name], { stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`Installing ${name} failed (${code})`)));
  });
}
function enableInstalled(directory, name, scanDirectory, { php = 'php', environmentFile = process.env.GITHUB_ENV } = {}) {
  const entry = readEntry(directory, name);
  const prefix = entry.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  const destination = path.join(prefix, 'var/php-darwin/extensions', entry.sha256);
  if (fs.realpathSync(destination) !== destination) throw new Error('Unsafe installed extension directory');
  const installedMetadata = JSON.parse(fs.readFileSync(path.join(destination, 'metadata.json'), 'utf8'));
  if (key(installedMetadata) !== key(entry) || installedMetadata.inputs_sha256 !== entry.inputs_sha256) {
    throw new Error('Installed extension metadata changed');
  }
  const environment = packEnvironment(installedMetadata, destination);
  const env = { ...process.env, ...environment };
  const loaded = JSON.parse(command(php, ['-r', 'echo json_encode(get_loaded_extensions());'], { env })).map(value => value.toLowerCase());
  const missing = packs[name].filter(module => !loaded.includes(module));
  fs.mkdirSync(scanDirectory, { recursive: true });
  if (fs.realpathSync(scanDirectory) !== scanDirectory) throw new Error('PHP configuration directory traverses a symlink');
  const ini = path.join(scanDirectory, `zz-php-darwin-${name}.ini`);
  const marker = '; Managed by php-darwin optional extension installer\n';
  let previous;
  let iniStat;
  try { iniStat = fs.lstatSync(ini); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (iniStat) {
    if (!iniStat.isFile()) throw new Error('Unsafe optional extension configuration');
    previous = fs.readFileSync(ini, 'utf8');
    if (!previous.startsWith(marker)) throw new Error('Refusing to replace an existing extension configuration');
  }
  const temporary = path.join(scanDirectory, `.php-darwin-${name}.tmp`);
  let changed = false;
  try {
    if (missing.length) {
      fs.writeFileSync(temporary, (previous || marker) + missing.map(module => `extension=${module}.so\n`).join(''), { flag: 'wx' });
      fs.renameSync(temporary, ini);
      changed = true;
    }
    command(php, ['-r', `exit(${packs[name].map(module => `extension_loaded('${module}')`).join(' && ')} ? 0 : 1);`], { env });
    // Actions imports this for following steps. Standalone users can source the
    // persistent environment file; no shell startup file or service is changed.
    if (Object.keys(environment).length) {
      const exports = Object.entries(environment).map(([variable, value]) => `export ${variable}='${value.replaceAll("'", "'\\''")}'\n`).join('');
      fs.writeFileSync(path.join(destination, 'environment.sh'), exports);
      if (environmentFile) fs.appendFileSync(environmentFile,
        Object.entries(environment).map(([variable, value]) => `${variable}=${value}\n`).join(''));
      else console.log(`Extension environment: ${path.join(destination, 'environment.sh')}`);
    }
  } catch (error) {
    if (changed) {
      if (previous === undefined) fs.rmSync(ini, { force: true });
      else fs.writeFileSync(ini, previous);
    }
    throw error;
  } finally { fs.rmSync(temporary, { force: true }); }
}
async function activate(directory, base, scanDirectory, { installPack = installDownloaded, enablePack = enableInstalled } = {}) {
  validateContext(base);
  const prefix = base.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  const config = base.php_version + (base.build === 'debug' ? '-debug' : '') + (base.thread_safety === 'zts' ? '-zts' : '');
  if (scanDirectory !== `${prefix}/etc/php/${config}/conf.d`) throw new Error('Invalid optional extension configuration directory');
  const names = requestedPacks(directory);
  const installed = await Promise.allSettled(names.map(async name => {
    const entry = readEntry(directory, name);
    validateBase(entry, base);
    await installPack(directory, name);
    return name;
  }));
  const enabled = [];
  // Enable after all independent installations finish, so PHP never reads a
  // half-written configuration or loads a serializer before it is installed.
  for (const [index, result] of installed.entries()) {
    try {
      if (result.status === 'rejected') throw result.reason;
      await enablePack(directory, result.value, scanDirectory);
      enabled.push(result.value);
    } catch (error) {
      console.warn(`Extension cache ${names[index]} unavailable; caller fallback remains available: ${error.message}`);
    }
  }
  return enabled;
}
function phpApi(phpConfig = 'php-config') {
  const include = command(phpConfig, ['--include-dir']);
  const header = fs.readFileSync(path.join(include, 'Zend/zend_modules.h'), 'utf8');
  const match = header.match(/^#define\s+ZEND_MODULE_API_NO\s+(\d{8})\b/m);
  if (!match) throw new Error('Missing PHP module API in installed headers');
  return match[1];
}
function runtimeContext(phpConfig = 'php-config') {
  const version = command(phpConfig, ['--version']);
  if (!/^\d+\.\d+\.\d+(?:[A-Za-z+-][0-9A-Za-z.+-]*)?$/.test(version)) throw new Error('Invalid php-config version');
  const flags = command(phpConfig, ['--configure-options']).replaceAll("'", '').split(/\s+/);
  const enabled = option => flags.includes(option) || flags.includes(option + '=yes');
  return { php_version: version.split('.').slice(0, 2).join('.'), build: enabled('--enable-debug') ? 'debug' : 'release',
    thread_safety: enabled('--enable-zts') || enabled('--enable-maintainer-zts') ? 'zts' : 'nts',
    architecture: process.arch === 'arm64' ? 'arm64' : 'x86_64',
    php_api: phpApi(phpConfig), extension_dir: command(phpConfig, ['--extension-dir']) };
}
function inspectTree(root) {
  function walk(directory) {
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, item.name);
      if (item.isSymbolicLink()) {
        const target = fs.readlinkSync(file);
        if (path.isAbsolute(target) || !path.resolve(path.dirname(file), target).startsWith(root + path.sep) ||
            !fs.realpathSync(file).startsWith(fs.realpathSync(root) + path.sep)) throw new Error('Unsafe pack symlink');
      } else if (item.isDirectory()) walk(file);
      else if (!item.isFile()) throw new Error('Unsupported pack member');
    }
  }
  walk(root);
}
function packEnvironment(metadata, destination) {
  const environment = {};
  for (const [name, values] of Object.entries(metadata.environment || {})) {
    if (!['MAGICK_CONFIGURE_PATH', 'MAGICK_CODER_MODULE_PATH', 'MAGICK_FILTER_MODULE_PATH', 'SASL_PATH'].includes(name) ||
        !Array.isArray(values) || !values.every(safePath)) throw new Error('Invalid pack environment');
    environment[name] = values.map(value => path.join(destination, value)).join(path.delimiter);
  }
  return environment;
}
function relocateResources(metadata, stage, destination) {
  if (!Array.isArray(metadata.relocations)) throw new Error('Missing resource relocation metadata');
  for (const relative of metadata.relocations) {
    if (!safePath(relative) || !relative.endsWith('.la')) throw new Error('Unsafe resource relocation');
    const file = path.join(stage, relative);
    if (!fs.lstatSync(file).isFile() || fs.statSync(file).size > 1000000) throw new Error('Invalid resource descriptor');
    const content = fs.readFileSync(file, 'utf8');
    if (!content.includes('@PHP_DARWIN_EXTENSION_ROOT@')) throw new Error('Missing resource relocation marker');
    fs.writeFileSync(file, content.replaceAll('@PHP_DARWIN_EXTENSION_ROOT@', destination));
  }
}
function readEntry(directory, name) {
  if (!Object.hasOwn(packs, name)) throw new Error('Unknown extension pack');
  const entry = validateEntry(JSON.parse(fs.readFileSync(path.join(directory, `${name}.json`), 'utf8')));
  if (entry.name !== name) throw new Error('Extension cache name mismatch');
  return entry;
}
function verifyArchive(directory, entry) {
  const archive = path.join(directory, entry.file);
  const data = fs.readFileSync(archive);
  if (data.length !== entry.bytes || digest(data) !== entry.sha256) throw new Error('Extension archive changed after download');
  return archive;
}
function preparedMetadata(stage, entry) {
  if (!fs.lstatSync(stage).isDirectory()) throw new Error('Invalid extension staging directory');
  inspectTree(stage);
  const metadata = JSON.parse(fs.readFileSync(path.join(stage, 'metadata.json'), 'utf8'));
  if (metadata.schema !== 1 || key(metadata) !== key(entry) || metadata.php_api !== entry.php_api ||
      metadata.inputs_sha256 !== entry.inputs_sha256 || JSON.stringify(metadata.modules) !== JSON.stringify(packs[entry.name])) {
    throw new Error('Extension archive metadata mismatch');
  }
  for (const module of metadata.modules) {
    if (!fs.lstatSync(path.join(stage, 'modules', `${module}.so`)).isFile()) throw new Error('Missing extension module');
  }
  return metadata;
}
function prepareArchive(directory, name) {
  const entry = readEntry(directory, name);
  const archive = verifyArchive(directory, entry);
  const ready = path.resolve(directory, `${name}-${entry.sha256}.stage`);
  const stage = fs.mkdtempSync(path.resolve(directory, `.prepare-${name}-`));
  try {
    const listing = command('tar', ['--zstd', '-tf', archive]).split('\n');
    if (!listing.every(member => safePath(member.replace(/\/$/, '')))) throw new Error('Unsafe extension archive path');
    command('tar', ['--zstd', '--no-same-owner', '-xf', archive, '-C', stage]);
    preparedMetadata(stage, entry);
    fs.renameSync(stage, ready);
    return ready;
  } finally {
    fs.rmSync(stage, { recursive: true, force: true });
  }
}
function prepareDownloaded(directory, name) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [__filename, 'prepare', directory, name], { stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`Preparing ${name} failed (${code})`)));
  });
}
function movePrepared(stage, destination) {
  try { fs.renameSync(stage, destination); }
  catch (error) {
    if (error.code !== 'EXDEV') throw error;
    // RUNNER_TEMP may be on another volume. Keep the final move atomic there.
    const local = fs.mkdtempSync(path.join(path.dirname(destination), '.install-'));
    try {
      fs.cpSync(stage, local, { recursive: true, verbatimSymlinks: true });
      fs.renameSync(local, destination);
    } finally { fs.rmSync(local, { recursive: true, force: true }); }
  }
}
function install(directory, name, { phpConfig = 'php-config', php = 'php' } = {}) {
  const entry = readEntry(directory, name);
  const actual = runtimeContext(phpConfig, php);
  if (entry.name !== name || !['php_version', 'build', 'thread_safety', 'architecture', 'php_api'].every(field => actual[field] === entry[field])) {
    throw new Error('Extension cache does not match installed PHP');
  }
  if (Number(command('sw_vers', ['-productVersion']).split('.')[0]) < entry.minimum_macos) throw new Error('Extension cache requires newer macOS');
  const prefix = actual.architecture === 'arm64' ? '/opt/homebrew' : '/usr/local';
  if (!actual.extension_dir.startsWith(prefix + '/') || !fs.statSync(actual.extension_dir).isDirectory()) throw new Error('Invalid PHP extension directory');
  const stage = path.resolve(directory, `${name}-${entry.sha256}.stage`);
  if (fs.existsSync(stage)) verifyArchive(directory, entry);
  else prepareArchive(directory, name);
  const store = path.join(prefix, 'var/php-darwin/extensions');
  fs.mkdirSync(store, { recursive: true });
  if (fs.realpathSync(store) !== store) throw new Error('Extension store traverses a symlink');
  const destination = path.join(store, entry.sha256);
  const previous = [];
  let committed = false;
  try {
    const metadata = preparedMetadata(stage, entry);
    relocateResources(metadata, stage, destination);
    if (!fs.existsSync(destination)) movePrepared(stage, destination);
    else {
      if (fs.realpathSync(destination) !== destination ||
          fs.readFileSync(path.join(destination, 'metadata.json'), 'utf8') !== fs.readFileSync(path.join(stage, 'metadata.json'), 'utf8')) {
        throw new Error('Installed private extension cache is inconsistent');
      }
      inspectTree(destination);
    }
    // mkdtemp creates a private staging directory. Installed runtime files must
    // also be readable by PHP processes running under another account.
    fs.chmodSync(destination, 0o755);
    const environment = packEnvironment(metadata, destination);
    const args = metadata.modules.flatMap(module => ['-d', `extension=${path.join(destination, 'modules', `${module}.so`)}`]);
    command(php, ['-n', ...args, '-r', `exit(extension_loaded('${name}') ? 0 : 1);`], { env: { ...process.env, ...environment } });
    // Only install modules after the entire private pack loads successfully.
    for (const module of metadata.modules) {
      const target = path.join(actual.extension_dir, `${module}.so`);
      // Serializer modules can already be supplied by the PHP cache or user.
      if (module !== name && fs.existsSync(target)) continue;
      const backup = path.join(directory, `${module}.previous`);
      let hadPrevious = false;
      try { fs.lstatSync(target); fs.renameSync(target, backup); hadPrevious = true; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      previous.push({ target, backup, hadPrevious });
      fs.symlinkSync(path.join(destination, 'modules', `${module}.so`), target);
    }
    const installedArgs = metadata.modules.flatMap(module => ['-d', `extension=${path.join(actual.extension_dir, `${module}.so`)}`]);
    command(php, ['-n', ...installedArgs, '-r', `exit(extension_loaded('${name}') ? 0 : 1);`], { env: { ...process.env, ...environment } });
    fs.writeFileSync(path.join(directory, `${name}.env`), Object.entries(environment).map(([variable, value]) => `${variable}=${value}\n`).join(''));
    fs.writeFileSync(path.join(directory, `${name}.modules`), metadata.modules.join('\n') + '\n');
    committed = true;
    console.log(`Installed ${name} from its separate extension cache`);
    return { modules: metadata.modules, environment, destination };
  } finally {
    if (!committed) for (const item of previous.reverse()) {
      fs.rmSync(item.target, { force: true });
      if (item.hadPrevious) fs.renameSync(item.backup, item.target);
    }
    else for (const item of previous) if (item.hadPrevious) fs.rmSync(item.backup, { force: true });
    fs.rmSync(stage, { recursive: true, force: true });
  }
}
module.exports = { packs, origins, command, digest, safePath, key, validateContext, validateEntry, phpApi,
  selectRequested, requestedPacks, validateBase, activate, enableInstalled, download, prefetch, runtimeContext, inspectTree, packEnvironment, relocateResources, prepareArchive, movePrepared, install };
if (require.main === module) (async () => {
  const [mode, directory, ...args] = process.argv.slice(2);
  if (!directory) throw new Error('Extension staging directory required');
  if (mode === 'select' && args.length === 1) {
    fs.writeFileSync(path.join(directory, 'requested.txt'), selectRequested(args[0]).join('\n'));
  } else if (mode === 'prefetch-requested' && args.length === 4) {
    const [php_version, build, thread_safety, architecture] = args;
    const names = requestedPacks(directory);
    if (names.length) await prefetch(directory, { php_version, build, thread_safety, architecture }, names);
  } else if (mode === 'activate' && args.length === 2) {
    await activate(directory, JSON.parse(fs.readFileSync(args[0], 'utf8')), args[1]);
  } else if (mode === 'prefetch') {
    const [php_version, build, thread_safety, architecture, ...names] = args;
    await prefetch(directory, { php_version, build, thread_safety, architecture }, names);
  } else if (mode === 'prepare' && args.length === 1) prepareArchive(directory, args[0]);
  else if (mode === 'install' && args.length === 1) install(directory, args[0]);
  else throw new Error('Usage: install-extensions.cjs select|prefetch-requested|activate|prefetch|prepare|install DIRECTORY ...');
})().catch(error => { console.error(`php-darwin extensions: ${error.message}`); process.exitCode = 1; });
