# Published macOS PHP checks

Install PHP 5.3–8.5 through the pinned setup-php v2 action on GitHub-hosted macOS 14/15/26 ARM and macOS 15 Intel. These are normal NTS release installations.

The workflow starts without preinstalled PHP, validates live public release metadata, compares installed PHP/CGI/FPM and module bytes with the published archive, checks startup diagnostics and default extensions, exercises core functions and CGI, validates FPM configuration, and tests Imagick PNG/JPEG encoding, decoding and resizing. The second setup-php invocation must preserve the default module inventory except for adding Imagick.

Package transfers happen only on Actions runners. Logs, inventories, byte proofs and reports are retained as artifacts. No packages are rebuilt or published. A smoke pass is not an exhaustive regression or security assessment.
