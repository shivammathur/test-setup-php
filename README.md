## VS18 CLI Server Crash Repro

This orphan branch contains a single workflow that replays the VS18 x86 TS source-test failure from `shivammathur/php-windows-builder` run `26068816066`.

It downloads the original build artifacts, runs `Invoke-PhpTests` the same way as `test-php-libs-from-source.yml`, and injects a CLI-server dump listener around the failing test path.
