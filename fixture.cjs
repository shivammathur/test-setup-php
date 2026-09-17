const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const test = require('./cases.cjs').find(test => test.id === process.env.CASE_ID);
if (!test) throw new Error('Unknown case');
const files = {};
const put = (name, content) => {
  fs.mkdirSync(path.dirname(name), {recursive: true});
  fs.writeFileSync(name, content);
  files[name] = createHash('sha256').update(content).digest('hex');
};
const lock = (value, directory = '.') => put(path.join(directory, 'composer.lock'), JSON.stringify({'platform-overrides': {php: value}}));
const json = (value, directory = '.') => put(path.join(directory, 'composer.json'), JSON.stringify({config: {platform: {php: value}}}));
let input = '', versionFile = '', project = '';
switch (test.source) {
  case 'input': input = test.value; break;
  case 'plain': put('.php-version', test.value); break;
  case 'asdf': versionFile = '.tool-versions'; put(versionFile, `ruby 3.3.0\nphp ${test.value}\nnode 24.0.0\n`); break;
  case 'input-precedence': input = test.value; put('.php-version', ';id'); lock(';id'); json(';id'); break;
  case 'file-precedence': put('.php-version', test.value); lock(';id'); json(';id'); break;
  case 'lock-precedence': lock(test.value); json(';id'); break;
  case 'json': json(test.value); break;
  case 'lock-subdir': project = 'composer project'; lock(test.value, project); json(';id', project); break;
  case 'json-subdir': project = 'composer project'; json(test.value, project); break;
  case 'custom': versionFile = 'version config/php version'; put(versionFile, ` \t${test.value} \t\r\n`); break;
  case 'whitespace': versionFile = '.tool-versions'; put(versionFile, `#PHP\r\n\r\nruby 3.3.0\r\n \tphp \t ${test.value} \t# selected\r\nnode 24.0.0\r\n`); break;
  case 'comments': put('.php-version', `#PHP\n\n ${test.value} # $(echo COMPROMISED > e2e-pwned)\n`); break;
  case 'ignored': put('.php-version', `${test.value}\n$(echo COMPROMISED > e2e-pwned)\n`); break;
  case 'smoke': put('.php-version', test.value); break;
  case 'default': break;
  default: throw new Error('Unknown source');
}
const manifest = require('./action-under-test/src/configs/php-versions.json');
const expected = /^pre(?:-installed)?$/.test(test.value) ? '8.4' : manifest[test.value] || (test.value.length === 1 ? test.value + '.0' : test.value.slice(0, 3));
fs.writeFileSync('e2e-state.json', JSON.stringify({test, files, expected}));
fs.appendFileSync(process.env.GITHUB_OUTPUT, `input=${input}\nfile=${versionFile}\nproject=${project}\n`);
