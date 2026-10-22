const path = require('node:path');
const fixture = '.github/tests/phpunit-matchers/OutcomesTest.php';
const at = `${path.resolve(fixture)}:35`;
const diagnostic = (message, severity = 'warning', located = false) => ({message, severity, file: located ? fixture : null, line: located ? 35 : null});
const header = 'There was 1 skipped test:';
module.exports = name => {
  if (name === 'footers') {
    const footers = ['OK (1 test, 1 assertion)', 'OK, but there were issues!', 'OK, but some tests were skipped!', 'OK, but incomplete, skipped, or risky tests!', 'FAILURES!', 'ERRORS!', 'WARNINGS!', 'Tests: 2, Assertions: 2.', 'PHPUnit 12.5.40 by Sebastian Bergmann and contributors.'];
    return {
      output: footers.map((footer, i) => `${header}\n\nPreserved before footer ${i}\n\n${footer}\nUnrelated output after footer ${i}\n\n`).join(''),
      expected: footers.map((_, i) => diagnostic(`Preserved before footer ${i}`))
    };
  }
  if (name === 'transition') return {
    output: `${header}\nInitial warning\n1 test triggered 1 deprecation:\nUnrelated deprecation output\nThere was 1 failure:\n1) Boundary::failure\nFailed asserting that false is true.\n\n${at}\nFAILURES!\nUnrelated output\n`,
    expected: [diagnostic('Initial warning'), diagnostic('Failed asserting that false is true.', 'failure', true)]
  };
  const severity = name === 'error' ? 'failure' : name;
  const section = name === 'error' ? '1 test triggered 1 error:' : name === 'notice' ? 'There was 1 incomplete test:' : header;
  const messages = ['1) Boundary::diagnosticPrefixes', 'PHPUnit compatibility is not available', 'Tests: external service unavailable', 'OK for production, unavailable in CI', 'FAILURES in upstream service', 'There were errors: retry later', '2 tests triggered warnings: unavailable', at];
  return {
    output: [section, '', ...messages, '', 'OK, but some tests were skipped!', 'Unrelated output after summary', ''].join('\n'),
    expected: messages.map(message => diagnostic(name === 'error' ? message.replace(/^1\) /, '') : message, severity, message === at))
  };
};
module.exports.names = ['warning', 'notice', 'error', 'footers', 'transition'];
