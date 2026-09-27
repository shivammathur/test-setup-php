const extensionName = /^[a-z][a-z0-9_+-]*$/;

function releaseForFormula(formula) {
  const name = formula.split('/').at(-1);
  if (/^php(?:$|@|-)/.test(name)) return 'cache-php';
  const extension = name.match(/^([a-z][a-z0-9_+-]*)@[578]\.\d(?:$|-)/)?.[1];
  return extension ? `cache-${extension}` : 'cache';
}

function productionRelease(tag) {
  if (tag === 'cache') return true;
  const name = tag?.replace(/^cache-/, '');
  return tag?.startsWith('cache-') && extensionName.test(name) &&
    name !== 'locks' && !name.startsWith('source-');
}

function legacyRelease(tag) { return /^cache-source-[0-9a-f]{2}$/.test(tag); }

module.exports = { releaseForFormula, productionRelease, legacyRelease };
