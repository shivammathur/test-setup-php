dnl config.m4 for extension xz

PHP_ARG_WITH([xz],
  [for xz support],
  [AS_HELP_STRING([--with-xz],
    [Include xz support])])

if test "$PHP_XZ" != "no"; then

  LIBNAME=lzma # you may want to change this
  LIBSYMBOL=lzma_stream_encoder # you most likely want to change this

  AC_PATH_PROG(PKG_CONFIG, pkg-config, no)

  AC_MSG_CHECKING(for liblzma)
  if test -x "$PKG_CONFIG" && $PKG_CONFIG --exists liblzma; then
    LIBLZMA_INCLINE=`$PKG_CONFIG liblzma --cflags`
    LIBLZMA_LIBLINE=`$PKG_CONFIG liblzma --libs`
    LIBLZMA_VERSION=`$PKG_CONFIG liblzma --modversion`
    AC_MSG_RESULT(from pkg-config: version $LIBLZMA_VERSION)
    PHP_EVAL_LIBLINE($LIBLZMA_LIBLINE, XZ_SHARED_LIBADD)
    PHP_EVAL_INCLINE($LIBLZMA_INCLINE)
  else
    AC_MSG_WARN([not found using pkg-config, fallback to system directory])

    PHP_CHECK_LIBRARY($LIBNAME,$LIBSYMBOL,
    [
      PHP_ADD_LIBRARY($LIBNAME, 1, XZ_SHARED_LIBADD)
    ],[
      AC_MSG_ERROR([wrong xz lib version or lib not found])
    ])
  fi

  PHP_SUBST(XZ_SHARED_LIBADD)

  PHP_NEW_EXTENSION(xz, xz.c xz_fopen_wrapper.c utils.c, $ext_shared, -DZEND_ENABLE_STATIC_TSRMLS_CACHE=1)
fi
