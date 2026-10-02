# OpenSSL release validation

This orphan branch validates exact PHP Windows artifacts for PHP 8.4, 8.5, 8.6, and master. `qa-manifest.json` will pin source run IDs, immutable merged artifact IDs, ZIP digests, OpenSSL DLL digests, and runtime versions before the branch is pushed.

Each run verifies x86/x64 and TS/NTS variants, OpenSSL crypto and TLS behavior, and dependent extension loading. Source-build test reports and native dependency tests are reviewed separately.
