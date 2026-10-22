PHP_ARG_ENABLE([pecl_fixture], [whether to enable the PECL validation fixture], [AS_HELP_STRING([--enable-pecl_fixture], [Enable PECL validation fixture])], [yes])
PHP_NEW_EXTENSION([pecl_fixture], [pecl_fixture.c], [$ext_shared])
