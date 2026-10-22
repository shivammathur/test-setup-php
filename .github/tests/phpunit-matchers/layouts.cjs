const path = require('node:path');
const fixture = '.github/tests/phpunit-matchers/OutcomesTest.php';
const at = line => `${path.resolve(fixture)}:${line}`;
const assertion = 'Failed asserting that false is true.';
const cases = [
  ['plainBlank', 'failure', 10, `${assertion} [blank]`, '', at(10)],
  ['plainNoBlank', 'failure', 15, `${assertion} [no-blank]`, at(15)],
  ['customNoBlank', 'failure', 20, 'custom no blank', assertion, at(20)],
  ['customBlank', 'failure', 25, 'custom blank', assertion, '', at(25)],
  ['explicitFailure', 'failure', 20, 'explicit failure', '', at(20)],
  ['exception', 'failure', 25, 'RuntimeException: exception', '', at(25)],
  ['customLocation', 'failure', 52, 'invalid template.php:42', assertion, '', at(52)],
  ['riskyBlank', 'warning', 28, 'This test did not perform any assertions', '', at(28)],
  ['skippedReasonNoBlank', 'warning', 35, 'skipped reason', at(35)],
  ['skippedNoReasonNoBlank', 'warning', 40, at(40)],
  ['skippedDependency', 'warning', null, 'This test depends on "Layout::provider" to pass'],
  ['skippedNoReasonBlank', 'warning', 40, '', at(40)],
  ['skippedReasonBlank', 'warning', 35, 'skipped reason with blank', '', at(35)],
  ['riskyNoBlank', 'warning', 28, 'This test did not perform any assertions', at(28)]
];
module.exports = name => {
  if (['error', 'warning', 'notice'].includes(name)) {
    const severity = name === 'error' ? 'failure' : name;
    return {
      output: `1 test triggered 2 ${name}s:\n\n1) ${at(72)}\nFirst ${name} diagnostic\nContinuation detail\n\n2) ${at(73)}\nSecond ${name} diagnostic\n\n--\nTests: 2\n`,
      expected: [
        {message: at(72), severity, file: fixture, line: 72},
        {message: `First ${name} diagnostic`, severity, file: null, line: null},
        {message: 'Continuation detail', severity, file: null, line: null},
        {message: at(73), severity, file: fixture, line: 73},
        {message: `Second ${name} diagnostic`, severity, file: null, line: null}
      ]
    };
  }
  const [id, severity, line, ...body] = cases.find(x => x[0] === name);
  const header = `1) Layout::${id}`;
  const section = severity === 'failure' ? 'There was 1 failure:' : id.startsWith('risky') ? 'There was 1 risky test:' : 'There was 1 skipped test:';
  const expected = severity === 'failure'
    ? [{message: body[0], severity, file: fixture, line}]
    : [header, ...body.filter(Boolean)].map(message => ({message, severity, file: line && message === at(line) ? fixture : null, line: line && message === at(line) ? line : null}));
  return {output: [section, '', header, ...body, '', '--', ''].join('\n') + '\n', expected};
};
module.exports.names = [...cases.map(x => x[0]), 'error', 'warning', 'notice'];
