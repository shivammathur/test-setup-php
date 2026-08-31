# PHP GH-23484 Windows JIT debugger reproducer

This orphan branch reproduces [php/php-src#23484](https://github.com/php/php-src/issues/23484) with the official PHP 8.5.10 NTS x64 build on Windows Server 2022 and IIS FastCGI.

The first workload adapts the minimal reproducer from php/php-src#21710 to consecutive IIS requests. It deliberately links a method against an evaluated parent, trains a tracing-JIT root with one value type, ends the request so the heap-copied `op_array` can be freed, and then forces a side trace with the other value type. If that compact workload does not crash, the workflow runs the independently verified stock Laravel 13 reproducer under PHP's long-lived built-in server.

Before IIS starts `php-cgi.exe`, the workflow arms ProcDump for first-chance exceptions and configures WER as a fallback. Each full dump is analyzed by CDB using the official PHP debug pack. The uploaded artifact contains the dumps, full all-thread debugger traces, JIT debug output, request history, PHP configuration, and Windows crash events.
