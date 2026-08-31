# PHP GH-23484 A/B validation

This orphan branch compares the official PHP 8.5.10 NTS x64 build with a
source build of `PHP-8.5` at `38a666f4c121b7a7a09ba2a19b7d1d8757b93116`.

Both lanes run the same Laravel error-rendering workload under IIS FastCGI
and the PHP built-in server with tracing JIT enabled. ProcDump is armed for
first-chance access violations. The 8.5.10 lane must capture and symbolize a
crash; the `PHP-8.5` lane must complete both stress loops without a dump.
