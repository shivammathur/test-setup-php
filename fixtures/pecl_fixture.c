#include "php.h"
#include "fixture_version.h"

zend_module_entry pecl_fixture_module_entry = {
    STANDARD_MODULE_HEADER,
    "pecl_fixture",
    NULL, NULL, NULL, NULL, NULL, NULL,
    FIXTURE_VERSION,
    STANDARD_MODULE_PROPERTIES
};
ZEND_GET_MODULE(pecl_fixture)
