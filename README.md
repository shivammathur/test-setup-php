# PHP Darwin

[![Package cache](https://github.com/shivammathur/php-darwin/actions/workflows/cache-stable.yml/badge.svg)](https://github.com/shivammathur/php-darwin/actions/workflows/cache-stable.yml)
[![Validation](https://github.com/shivammathur/php-darwin/actions/workflows/validate.yml/badge.svg)](https://github.com/shivammathur/php-darwin/actions/workflows/validate.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Prebuilt Homebrew PHP packages for fast installation on macOS, used by
[setup-php](https://github.com/shivammathur/setup-php).

Each cache includes PHP, its required dependencies, coverage extensions and
Homebrew links. Installation preserves existing PHP versions, configuration and
services, and makes the cached PHP the default through Homebrew's `bin/php` link.

## Supported configurations

The cache covers ARM64 and Intel, with release/debug and NTS/ZTS variants.
[conf/versions](conf/versions) lists stable and nightly PHP versions;
[conf/platforms.json](conf/platforms.json) defines minimum macOS versions and
build/test runners. [conf/cached-extensions](conf/cached-extensions) contains one
file per PHP minor, with one cached extension name per line.

Imagick, MongoDB and Memcached have separate optional archives for PHP 5.6–8.7.
They are built against published PHP caches and refreshed independently, so
extension updates do not require rebuilding PHP or adding libraries to its cache.

## Installation

Use setup-php normally:

```yaml
- uses: shivammathur/setup-php@v2
  with:
    php-version: '8.4'
```

To install a published cache directly on a macOS runner:

```sh
curl --fail --location --output install.sh \
  https://github.com/shivammathur/php-darwin/releases/download/php-8.4/install.sh
bash install.sh 8.4 release nts
# Optional packs are selected and prepared in parallel by the installer.
bash install.sh 8.4 release nts "" "imagick, mongodb, memcached"
```

PHP package downloads use GitHub Releases first, with a checksum-verified
Cloudflare fallback. Cache builds use Cloudflare first for dependency bottles.
Homebrew handles bottle installation, relocation and linking.

## Workflows

| Workflow | Purpose |
| --- | --- |
| `cache-stable.yml` / `cache-nightly.yml` | Build, test and publish a PHP cache |
| `cache-extensions.yml` | Refresh separate extension packs every six hours and validate before publishing |
| `update.yml` / `update-nightly.yml` | Detect changes and dispatch builds |
| `cache-bottles.yml` | Populate Cloudflare with exact upstream dependency bottles |
| `cache-source-bottles.yml` | Mirror reusable bottles built from source |
| `mirror.yml` | Mirror published PHP packages or refresh their installers |
| `validate.yml` | Run local regression tests and artifact-transfer checks |
| `test-source-cache.yml` | Test native source builds and cold/warm restoration |
| `update-dependencies.yml` | Prepare, verify and approve dependency bottles independently of PHP cache builds |
| `test.yml` / `e2e.yml` | Validate build artifacts and published installations |

## Development

```sh
bash scripts/installer/generate-install.sh
bash scripts/tests/run.sh
# Validate workflow syntax and embedded shell commands:
actionlint
```

The local suite requires Bash, Node.js 24+, Ruby 3.1+, Python 3, jq, Zstd, Git, curl, tar, zip and
unzip. On macOS it uses Homebrew's installed portable Ruby when available.
Native Homebrew and authenticated GitHub tests run separately in Actions.

See [maintenance](docs/maintenance.md) for the directory layout, workflow
commands, publishing requirements and troubleshooting.

## License

[MIT](LICENSE).
