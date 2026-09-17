const values = ['8', '8.4', '8.4.2', 'lowest', 'highest', 'latest', 'nightly', 'master', 'pre', 'pre-installed', '5.x', '7.x', '8.x'];
const cases = ['input', 'plain', 'asdf'].flatMap(source =>
  values.map(value => ({id: `${source}-${value}`, source, value}))
);
cases.push(
  {id: 'input-precedence', source: 'input-precedence', value: '8.4'},
  {id: 'file-precedence', source: 'file-precedence', value: '8.4'},
  {id: 'lock-precedence', source: 'lock-precedence', value: '8.4'},
  {id: 'composer-json', source: 'json', value: '8.4'},
  {id: 'lock-subdirectory', source: 'lock-subdir', value: '8.4'},
  {id: 'json-subdirectory', source: 'json-subdir', value: '8.4'},
  {id: 'custom-path-spaces', source: 'custom', value: '8.4'},
  {id: 'asdf-crlf-comments', source: 'whitespace', value: 'latest'},
  {id: 'plain-comments', source: 'comments', value: '8.4'},
  {id: 'default-latest', source: 'default', value: 'latest'},
  {id: 'ignored-shell-lines', source: 'ignored', value: '8.4'},
  {id: 'ini-extensions-composer', source: 'smoke', value: '8.4'}
);
module.exports = cases;
if (require.main === module) {
  const include = ['ubuntu-24.04', 'windows-2022', 'macos-15'].flatMap(os =>
    cases.map(test => ({os, ...test, pre: /^pre(?:-installed)?$/.test(test.value)}))
  );
  console.log(JSON.stringify({include}));
}
