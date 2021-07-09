dnl config.m4 for extension xz

PHP_ARG_WITH([xz],
  [for xz support],
  [AS_HELP_STRING([--with-xz],
    [Include xz support])])

if test "$PHP_XZ" != "no"; then

  LIBNAME=lzma # you may want to change this
  LIBSYMBOL=lzma_stream_encoder # you most likely want to change this

  PHP_CHECK_LIBRARY($LIBNAME,$LIBSYMBOL,
  [
    PHP_ADD_LIBRARY($LIBNAME, 1, XZ_SHARED_LIBADD)
  ],[
    AC_MSG_ERROR([wrong xz lib version or lib not found])
  ])
  PHP_SUBST(XZ_SHARED_LIBADD)

  PHP_NEW_EXTENSION(xz, xz.c xz_fopen_wrapper.c utils.c, $ext_shared, -DZEND_ENABLE_STATIC_TSRMLS_CACHE=1)
fi
