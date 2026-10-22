const path = require('node:path');
const fixture = '.github/tests/phpunit-matchers/OutcomesTest.php';
const diagnostic = (message, severity, line = null) => ({message, severity, file: line === null ? null : fixture, line});
const location = (line, severity, indent = '') => diagnostic(`${indent}${path.resolve(fixture)}:${line}`, severity, line);
module.exports = (major, group) => {
  if (group === 'failures') return [
    [25, 'RuntimeException: PR1138 unexpected exception'],
    [10, 'Failed asserting that false is true.'],
    [15, 'PR1138 custom assertion message'],
    [20, 'PR1138 explicit failure'],
    [52, 'PR1138 invalid attribute in template.php:42'],
    [57, 'PR1138 multiline assertion message'],
    [62, 'PR1138 assertion with diff']
  ].map(([line, message]) => diagnostic(message, 'failure', line));
  if (group === 'risky') return [
    diagnostic('1) OutcomesTest::testRisky', 'warning'),
    diagnostic('This test did not perform any assertions', 'warning'),
    location(28, 'warning'),
    diagnostic('2) OutcomesTest::testSecondRisky', 'warning'),
    diagnostic('This test did not perform any assertions', 'warning'),
    location(83, 'warning'),
    diagnostic('1) OutcomesTest::testIncomplete', 'notice'),
    diagnostic('PR1138 incomplete test', 'notice'),
    diagnostic('Second incomplete detail', 'notice'),
    location(67, 'notice')
  ];
  if (group === 'skips') return [
    diagnostic('1) OutcomesTest::testSkippedReason', 'warning'),
    diagnostic('PR1138 skipped with reason', 'warning'),
    diagnostic('Second skipped detail', 'warning'),
    ...(major === 9 ? [location(35, 'warning')] : []),
    diagnostic('2) OutcomesTest::testSkippedNoReason', 'warning'),
    ...(major === 9 ? [location(40, 'warning')] : []),
    diagnostic('3) OutcomesTest::testSkippedDependency', 'warning'),
    diagnostic('This test depends on "OutcomesTest::testSkippedReason" to pass' + (major === 9 ? '.' : ''), 'warning')
  ];
  if (group === 'issues') {
    if (major === 9) return [
      diagnostic('PR1138 native user warning', 'failure', 72),
      diagnostic('PR1138 native user notice', 'failure', 79)
    ];
    return [
      ...issue('warning', 'Warning', 72, 73, 70, major),
      ...issue('notice', 'Notice', 79, 80, 77, major)
    ];
  }
  throw new Error(`Unknown group: ${group}`);
};
function issue(severity, method, first, second, start, major) {
  const trigger = major === 10 ? [diagnostic(`* OutcomesTest::testUser${method}`, severity), location(start, severity, '  ')] : [];
  return [
    location(first, severity),
    diagnostic(`PR1138 native user ${severity}`, severity),
    diagnostic(`Second ${severity} detail`, severity),
    ...trigger,
    location(second, severity),
    diagnostic(`PR1138 second native ${severity}`, severity),
    ...trigger
  ];
}
