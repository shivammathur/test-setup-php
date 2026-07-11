# Windows Server 2025 COM diagnostics

This orphan branch reproduces php-src `ext/com_dotnet/tests/bug64130.phpt`
with x86 PHP master builds on Windows Server 2022 and the GitHub-hosted
`windows-2025-vs2026` image. It records IE policy/registration state and tests
minimal cleanup, delay, no-probe, and bounded activation-retry variants without
skipping the real assertion.
