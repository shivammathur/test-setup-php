#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "fixture.h"

PHP_FUNCTION(extra_path_fixture_add)
{
    zend_long left;
    zend_long right;

    ZEND_PARSE_PARAMETERS_START(2, 2)
        Z_PARAM_LONG(left)
        Z_PARAM_LONG(right)
    ZEND_PARSE_PARAMETERS_END();

    RETURN_LONG(fixture_add((int) left, (int) right));
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_extra_path_fixture_add, 0, 2, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, left, IS_LONG, 0)
    ZEND_ARG_TYPE_INFO(0, right, IS_LONG, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry extra_path_fixture_functions[] = {
    PHP_FE(extra_path_fixture_add, arginfo_extra_path_fixture_add)
    PHP_FE_END
};

zend_module_entry extra_path_fixture_module_entry = {
    STANDARD_MODULE_HEADER,
    "extra_path_fixture",
    extra_path_fixture_functions,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    "0.1.0",
    STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_EXTRA_PATH_FIXTURE
#ifdef ZTS
ZEND_TSRMLS_CACHE_DEFINE()
#endif
ZEND_GET_MODULE(extra_path_fixture)
#endif
