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
    PHP_ADD_LIBRARY_WITH_PATH($LIBNAME, $XZ_DIR/lib, XZ_SHARED_LIBADD)
    AC_DEFINE(HAVE_XZLIB,1,[ ])
  ],[
    AC_MSG_ERROR([wrong xz lib version or lib not found])
  ],[
    -L$XZ_DIR/lib -lm
  ])
  PHP_SUBST(XZ_SHARED_LIBADD)

  PHP_NEW_EXTENSION(xz, xz.c xz_fopen_wrapper.c utils.c, $ext_shared)
fi
