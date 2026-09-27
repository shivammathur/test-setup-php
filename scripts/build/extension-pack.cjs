const fs = require('node:fs');
const path = require('node:path');
const { command, digest, key, packs, inspectTree, packEnvironment, phpApi } = require('../installer/install-extensions.cjs');
const { recipeInputs } = require('../lib/recipe-inputs.cjs');

const macho = new Set(['cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca']);
function isMachO(file) {
  const fd = fs.openSync(file, 'r');
  const header = Buffer.alloc(4);
  try { fs.readSync(fd, header, 0, 4, 0); } finally { fs.closeSync(fd); }
  return macho.has(header.toString('hex'));
}
function dependencies(file) {
  return command('otool', ['-L', file]).split('\n').slice(1)
    .map(line => line.trim().replace(/ \(compatibility version.*$/, '')).filter(Boolean);
}
function files(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(item => {
    const file = path.join(directory, item.name);
    return item.isDirectory() ? files(file) : [file];
  });
}
function copyRuntime(keg, output) {
  fs.cpSync(keg, output, { recursive: true, verbatimSymlinks: true, filter: source => {
    const relative = path.relative(keg, source);
    if (/(?:^|\/)(?:include|\.brew|cmake|pkgconfig)(?:\/|$)/.test(relative)) return false;
    if (/\.(?:a|o|h|hpp|pc)$/.test(relative)) return false;
    // ImageMagick's libltdl module loader needs its .la module descriptors.
    if (relative.endsWith('.la') && !/\/modules-[^/]+\//.test(relative)) return false;
    if (/(?:^|\/)(?:man|gnuman|info)(?:\/|$)/.test(relative)) return false;
    if (/^share\/doc(?:\/|$)/.test(relative) && !fs.lstatSync(source).isDirectory() &&
        (!fs.lstatSync(source).isFile() ||
         !/^(?:licen[cs]e|copying|copyright|notice|legal|authors)(?:$|[.-])/i.test(path.basename(source)))) return false;
    return true;
  } });
}
function sourceRecords(formulae) {
  return formulae.map(formula => {
    const recipe = command('brew', ['formula', formula]);
    const tapName = formula.includes('/') ? formula.split('/').slice(0, 2).join('/') : 'homebrew/core';
    const tap = command('brew', ['--repository', tapName]);
    // Release/NTS can use an upstream bottle while other variants use source.
    // Preserve usable bottle changes, excluding only unrelated platform tags.
    const mode = 'platforms';
    const repository = tapName === 'homebrew/core' ? 'Homebrew/homebrew-core' : tapName.replace('/', '/homebrew-');
    return { formula, repository,
      path: path.relative(tap, recipe), sha256: digest(fs.readFileSync(recipe)),
      inputs_schema: 1, inputs_mode: mode, inputs_sha256: recipeInputs(recipe, mode) };
  });
}
function packageExtension({ name, php_version, build, thread_safety, architecture, output, extensionDirectory, php }) {
  if (!Object.hasOwn(packs, name)) throw new Error('Unknown extension pack');
  output = path.resolve(output);
  const prefix = command('brew', ['--prefix']);
  const references = packs[name].map(module => `shivammathur/extensions/${module}@${php_version}`);
  const runtime = new Set();
  for (const reference of references) {
    for (const dependency of command('brew', ['deps', '--installed', '--formula', reference]).split('\n').filter(Boolean)) {
      if (!references.includes(dependency) && !/^(?:.*\/)?(?:igbinary|msgpack)@/.test(dependency)) runtime.add(dependency);
    }
  }
  if ([...runtime].some(formula => /(?:^|\/)php(?:@|$)/.test(formula))) throw new Error('Extension runtime must not include PHP');
  const info = runtime.size ? JSON.parse(command('brew', ['info', '--json=v2', '--formula', ...runtime])).formulae : [];
  const metadata = { schema: 1, name, php_version, build, thread_safety, architecture,
    php_api: phpApi(path.join(path.dirname(php), 'php-config')),
    php_semver: command(path.join(path.dirname(php), 'php-config'), ['--version']),
    ...(process.env.PHP_DARWIN_PHP_SRC_COMMIT ? { php_src_commit: process.env.PHP_DARWIN_PHP_SRC_COMMIT } : {}),
    minimum_macos: architecture === 'arm64' ? 14 : 15, modules: packs[name], environment: {},
    source_records: sourceRecords([...new Set([...references, ...runtime])]),
    dependencies: info.map(formula => ({ name: formula.name,
      versions: [path.basename(fs.realpathSync(path.join(prefix, 'opt', formula.name)))] })) };
  const tap = command('brew', ['--repository', 'shivammathur/extensions']);
  metadata.source_records.push({ repository: 'shivammathur/homebrew-extensions', path: 'Abstract/abstract-php-extension.rb',
    sha256: digest(command('git', ['-C', tap, 'show', 'HEAD:Abstract/abstract-php-extension.rb']) + '\n') });
  metadata.inputs_sha256 = digest(JSON.stringify(metadata));
  fs.mkdirSync(output, { recursive: true });
  const stage = fs.mkdtempSync(path.join(output, '.pack-'));
  const mappings = [];
  try {
    fs.mkdirSync(path.join(stage, 'modules'));
    for (const module of metadata.modules) {
      const source = path.join(extensionDirectory, `${module}.so`);
      fs.copyFileSync(source, path.join(stage, 'modules', `${module}.so`));
      const moduleKeg = fs.realpathSync(path.join(prefix, 'opt', `${module}@${php_version}`));
      const licenseDir = path.join(stage, 'licenses', module);
      fs.mkdirSync(licenseDir, { recursive: true });
      for (const file of files(moduleKeg)) if (fs.lstatSync(file).isFile() &&
          /(?:licen[cs]e|copying|copyright|notice|authors)/i.test(path.basename(file))) {
        fs.copyFileSync(file, path.join(licenseDir, path.relative(moduleKeg, file).replaceAll('/', '_')));
      }
    }
    for (const formula of info) {
      const keg = fs.realpathSync(path.join(prefix, 'opt', formula.name));
      if (!keg.startsWith(prefix + '/Cellar/')) throw new Error('Runtime keg is outside Homebrew');
      const relative = path.join('kegs', path.relative(prefix + '/Cellar', keg));
      const destination = path.join(stage, relative);
      copyRuntime(keg, destination);
      mappings.push({ keg, opt: path.join(prefix, 'opt', formula.name), destination, relative, name: formula.name });
    }
    function relocated(reference, source) {
      if (reference.startsWith('/usr/lib/') || reference.startsWith('/System/Library/')) return reference;
      let absolute = reference;
      if (reference.startsWith('@loader_path/')) absolute = path.resolve(path.dirname(source), reference.slice(13));
      if (reference.startsWith('@rpath/')) {
        const basename = path.basename(reference);
        const matches = mappings.flatMap(mapping => files(mapping.destination).filter(file => path.basename(file) === basename));
        if (matches.length !== 1) throw new Error(`Ambiguous runtime library: ${reference}`);
        return matches[0];
      }
      for (const mapping of mappings) for (const root of [mapping.keg, mapping.opt]) {
        if (absolute.startsWith(root + '/')) return path.join(mapping.destination, path.relative(root, absolute));
      }
      throw new Error(`Unpackaged runtime library: ${reference} (${source})`);
    }
    const binaries = files(stage).filter(file => fs.lstatSync(file).isFile() && isMachO(file));
    for (const binary of binaries) {
      const mapping = mappings.find(item => binary.startsWith(item.destination + '/'));
      const source = mapping ? path.join(mapping.keg, path.relative(mapping.destination, binary)) : path.join(extensionDirectory, path.basename(binary));
      const changes = [];
      for (const reference of dependencies(binary)) {
        const target = relocated(reference, source);
        if (target === reference) continue;
        if (!fs.existsSync(target)) throw new Error(`Missing packaged library: ${target}`);
        changes.push('-change', reference, `@loader_path/${path.relative(path.dirname(binary), target)}`);
      }
      if (binary.endsWith('.dylib')) changes.push('-id', `@loader_path/${path.basename(binary)}`);
      if (changes.length) {
        fs.chmodSync(binary, fs.statSync(binary).mode | 0o200);
        command('install_name_tool', [...changes, binary]);
        command('codesign', ['--force', '--sign', '-', binary]);
      }
      for (const reference of dependencies(binary)) if (!reference.startsWith('@loader_path/') &&
          !reference.startsWith('/usr/lib/') && !reference.startsWith('/System/Library/')) {
        throw new Error(`Unrelocated library: ${reference}`);
      }
    }
    // Convert absolute keg symlinks to relative links inside this pack. Reject
    // external targets rather than depending on whatever happens to be installed.
    for (const file of files(stage)) if (fs.lstatSync(file).isSymbolicLink()) {
      const target = fs.readlinkSync(file);
      if (path.isAbsolute(target)) {
        const relocatedTarget = relocated(target, file);
        if (!relocatedTarget.startsWith(stage + '/')) throw new Error(`External runtime symlink: ${file}`);
        fs.unlinkSync(file);
        fs.symlinkSync(path.relative(path.dirname(file), relocatedTarget), file);
      }
    }
    metadata.relocations = [];
    for (const file of files(stage)) if (file.endsWith('.la') && fs.lstatSync(file).isFile()) {
      let content = fs.readFileSync(file, 'utf8');
      for (const mapping of mappings) for (const original of [mapping.keg, mapping.opt]) {
        content = content.replaceAll(original, `@PHP_DARWIN_EXTENSION_ROOT@/${mapping.relative}`);
      }
      if (content.includes('@PHP_DARWIN_EXTENSION_ROOT@')) {
        fs.writeFileSync(file, content);
        metadata.relocations.push(path.relative(stage, file));
      }
    }
    const sasl = mappings.find(item => item.name === 'cyrus-sasl');
    if (sasl && fs.existsSync(path.join(sasl.destination, 'lib/sasl2'))) {
      metadata.environment.SASL_PATH = [path.join(sasl.relative, 'lib/sasl2')];
    }
    const magick = mappings.find(item => item.name === 'imagemagick');
    if (magick) {
      const directories = [...new Set(files(magick.destination).map(file => path.dirname(file)))];
      for (const [variable, pattern] of [
        ['MAGICK_CODER_MODULE_PATH', /\/modules-[^/]+\/coders$/],
        ['MAGICK_FILTER_MODULE_PATH', /\/modules-[^/]+\/filters$/],
        ['MAGICK_CONFIGURE_PATH', /\/(?:etc|share)\/ImageMagick-[^/]+$/],
      ]) {
        const values = directories.filter(directory => pattern.test(directory)).map(directory => path.relative(stage, directory));
        if (values.length) metadata.environment[variable] = values;
      }
    }
    fs.writeFileSync(path.join(stage, 'metadata.json'), JSON.stringify(metadata, null, 2) + '\n');
    inspectTree(stage);
    const environment = packEnvironment(metadata, stage);
    command(php, ['-n', ...metadata.modules.flatMap(module => ['-d', `extension=${path.join(stage, 'modules', `${module}.so`)}`]),
      '-r', `exit(extension_loaded('${name}') ? 0 : 1);`], { env: { ...process.env, ...environment } });
    const temporaryArchive = path.join(output, `${key(metadata)}.tar.zst`);
    command('tar', ['--zstd', '-cf', temporaryArchive, '-C', stage, ...fs.readdirSync(stage).sort()],
      { env: { ...process.env, COPYFILE_DISABLE: '1', ZSTD_CLEVEL: '19', ZSTD_NBTHREADS: '0' } });
    const bytes = fs.readFileSync(temporaryArchive);
    const sha256 = digest(bytes);
    const file = `${key(metadata)}-${sha256}.tar.zst`;
    fs.renameSync(temporaryArchive, path.join(output, file));
    const entry = { ...metadata, file, sha256, bytes: bytes.length };
    fs.writeFileSync(path.join(output, `${key(metadata)}.json`), JSON.stringify(entry, null, 2) + '\n');
    console.log(`Packaged ${file}: ${bytes.length} bytes; ${binaries.length} relocated binaries`);
    return entry;
  } finally { fs.rmSync(stage, { recursive: true, force: true }); }
}
module.exports = { packageExtension, isMachO, dependencies, copyRuntime, sourceRecords };
if (require.main === module) {
  try {
    packageExtension({ name: process.env.EXTENSION_PACK, php_version: process.env.PHP_VERSION, build: process.env.BUILD,
      thread_safety: process.env.TS, architecture: process.env.ARCH, output: process.env.EXTENSION_PACK_OUTPUT || 'builds/extensions',
      extensionDirectory: process.argv[2], php: process.argv[3] });
  } catch (error) { console.error(error); process.exitCode = 1; }
}
