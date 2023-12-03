# Symfony swoole Bundle

[![App Tester](https://github.com/cesurapp/swoole-bundle/actions/workflows/testing.yaml/badge.svg)](https://github.com/cesurapp/swoole-bundle/actions/workflows/testing.yaml)
[![Software License](https://img.shields.io/badge/license-MIT-brightgreen.svg?logo=Unlicense)](LICENSE.md)

Template to create new symfony bundle.

Usage:
* Replace "Cesurapp\SwooleBundle" -> "GithubRepo\XYZBundle"
* Configure micro kernel -> tests/Kernel.php

Commands:
```shell
# PHPUnit Test
composer test
composer test:stop

# PHPCsFixer & PHPStan
composer qa:fix
composer qa:lint
composer qa:phpstan

# Test and Fix All
composer fix
```
