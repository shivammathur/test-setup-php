/* xz extension for PHP */

#ifndef PHP_XZ_H
# define PHP_XZ_H

extern zend_module_entry xz_module_entry;
extern php_stream_wrapper php_stream_xz_wrapper;

# define phpext_xz_ptr &xz_module_entry

# define PHP_XZ_VERSION "0.1.0"

/* The default size of the buffer used for compression and decompression. */
#define XZ_BUFFER_SIZE                  4096

#ifdef PHP_WIN32
#	define PHP_XZ_API __declspec(dllexport)
#elif defined(__GNUC__) && (__GNUC__ >= 4)
#	define PHP_XZ_API __attribute__ ((visibility("default")))
#else
#	define PHP_XZ_API
#endif

# if defined(ZTS) && defined(COMPILE_DL_XZ)
ZEND_TSRMLS_CACHE_EXTERN()
# endif

#ifdef ZTS
#	include "TSRM.h"
#endif

PHP_MINIT_FUNCTION(xz);
PHP_MSHUTDOWN_FUNCTION(xz);

PHP_MINFO_FUNCTION(xz);

PHP_FUNCTION(xzopen);
PHP_FUNCTION(xzencode);
PHP_FUNCTION(xzdecode);

php_stream *php_stream_xzopen(php_stream_wrapper *wrapper, const char *path,
	const char *mode_pass, int options, char **opened_path,
	php_stream_context *context STREAMS_DC TSRMLS_DC);

#ifdef ZTS
#	define XZ_G(v) TSRMG(xz_globals_id, zend_xz_globals *, v)
#else
#	define XZ_G(v) (xz_globals.v)
#endif

#endif	/* PHP_XZ_H */

/*
 * Local variables:
 * tab-width: 4
 * c-basic-offset: 4
 * End:
 * vim600: sw=4 ts=4 fdm=marker
 * vim<600: sw=4 ts=4
 */
