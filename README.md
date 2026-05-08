# PHP OpenLDAP Artifact QA

This orphan branch contains a broad workflow that validates PHP Windows artifacts against a real LDAP server.

The workflow downloads PHP artifacts from recent `shivammathur/php-windows-builder` runs, creates `C:\openldap\sysconf\ldap.conf`, starts a local in-memory LDAP server on `127.0.0.1:1389` with StartTLS and `127.0.0.1:1636` with LDAPS, loads `php_ldap.dll`, and runs direct PHP LDAP operations. It does not use PHPT tests.

The default run IDs are:

- PHP 8.2: `25557123127`
- PHP 8.3: `25557124547`
- PHP 8.4: `25557126274`
- PHP 8.5: `25557127793`

The config regression is covered by validating the embedded `php_ldap.dll` path, rejecting stale build paths, and asserting that options from `C:\openldap\sysconf\ldap.conf` are active at runtime.

The PHP checks cover extension loading, exported PHP 8 LDAP functions, plain LDAP, StartTLS, LDAPS, bind/bind_ext, read/list/search, entry and attribute iteration, binary values, controls, extended operations, add/delete/rename/modify APIs and their `_ext` variants, batch modifications, escaping, result parsing, and expected failure reporting.
