# OpenLDAP PHP Userland Regression Tests

This branch contains a pure PHP userland regression suite for Windows PHP LDAP
artifacts. It compares older OpenLDAP 2.6.x PHP builds against the OpenLDAP
2.7.0 upgrade artifacts and fails on removed functions/constants, behavior
changes, TLS/config regressions, write/read/search regressions, and unexpected
warnings or failures.

The suite intentionally does not import or run PHPT files from php-src.
