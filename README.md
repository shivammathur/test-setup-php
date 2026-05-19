## VS18 CLI Server Crash Repro

This orphan branch contains a single workflow that replays the VS18 x86 TS source-test failure from `shivammathur/php-windows-builder` run `26068816066`.

It downloads the original build artifacts, reconstructs the test environment with the pinned `php-windows-builder` harness, attaches ProcDump to the known flaky CLI-server child processes, and analyzes any captured dump with `cdb`.
