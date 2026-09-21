### GitHub-Hosted Runners

| Virtual environment    | Arch    | YAML workflow label                                       | Pre-installed PHP |
|------------------------|---------|-----------------------------------------------------------|-------------------|
| Ubuntu 26.04           | x86_64  | `ubuntu-26.04`                                            | `PHP 8.5`         |
| Ubuntu 24.04           | x86_64  | `ubuntu-latest` or `ubuntu-24.04`                         | `PHP 8.3`         |
| Ubuntu 22.04           | x86_64  | `ubuntu-22.04`                                            | `PHP 8.1`         |
| Ubuntu 26.04           | aarch64 | `ubuntu-26.04-arm`                                        | `PHP 8.5`         |
| Ubuntu 24.04           | aarch64 | `ubuntu-24.04-arm`                                        | `PHP 8.3`         |
| Ubuntu 22.04           | aarch64 | `ubuntu-22.04-arm`                                        | `PHP 8.1`         |
| Windows Server 2025    | x64     | `windows-latest`, `windows-2025` or `windows-2025-vs2026` | `PHP 8.5`         |
| Windows Server 2022    | x64     | `windows-2022`                                            | `PHP 8.5`         |
| Windows 11 ARM         | arm64   | `windows-11-arm` or `windows-11-vs2026-arm`               | `PHP 8.5`         |
| macOS Golden Gate 27.x | arm64   | `xcode-27`                                                | -                 |
| macOS Tahoe 26.x       | arm64   | `macos-latest` or `macos-26`                              | -                 |
| macOS Tahoe 26.x       | arm64   | `macos-latest` or `macos-26`                              | -                 |
| macOS Sequoia 15.x     | arm64   | `macos-15`                                                | -                 |
| macOS Sonoma 14.x      | arm64   | `macos-14`                                                | -                 |
| macOS Tahoe 26.x       | x86_64  | `macos-26-intel`                                          | `PHP 8.5`         |
| macOS Sequoia 15.x     | x86_64  | `macos-15-intel`                                          | `PHP 8.5`         |

> [!NOTE]
> Support for Intel (`x86_64`) macOS runners and macOS Sonoma 14.x (`macos-14`) arm64 runners is deprecated and will be removed completely in a future release of `setup-php`. We recommend migrating to arm64-based macOS runners running macOS 15 or newer, such as `macos-26` or `macos-15`.
