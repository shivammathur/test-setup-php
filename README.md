# Oniguruma PHP Artifact QA

This orphan branch contains a Windows workflow that validates PHP artifacts built
with custom `winlibs/winlib-builder` dependency runs and compares them with the
latest official Windows PHP release zips for the same PHP minor, architecture,
and thread-safety profile.

The tests are custom PHP functional checks, not `php-src` PHPT tests. They cover
general PHP runtime behavior plus the Oniguruma 6.9.8 -> 6.9.10 behavior surface
that is reachable through PHP's `mbstring` regex API. The suite also verifies
the expected Windows extension inventory, generated Unicode/property corpora,
and an expected-difference gate for artifact-vs-release comparisons.
