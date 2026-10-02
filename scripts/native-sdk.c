#include <stdio.h>
#include <string.h>
#include <apr_general.h>
#include <apr_pools.h>
#include <apr_strings.h>
#include <apr_base64.h>
#include <apr_xml.h>
#include <apr_version.h>
#include <apu_version.h>
#include <httpd.h>
#include <ap_release.h>

#if AP_SERVER_MAJORVERSION_NUMBER != 2 || AP_SERVER_MINORVERSION_NUMBER != 4 || AP_SERVER_PATCHLEVEL_NUMBER != 69
#error Unexpected Apache SDK version
#endif

int main(void)
{
    apr_pool_t *pool = NULL;
    char encoded[16] = {0};
    char decoded[16] = {0};
    char *copy;
    apr_xml_parser *parser;
    apr_xml_doc *document = NULL;
    const char *xml = "<sdk>apache-2.4.69</sdk>";
    if (apr_initialize() != APR_SUCCESS) return 1;
    if (apr_pool_create(&pool, NULL) != APR_SUCCESS) return 2;
    copy = apr_pstrdup(pool, "apache-sdk-2.4.69");
    if (!copy || strcmp(copy, "apache-sdk-2.4.69")) return 3;
    apr_base64_encode(encoded, "abc", 3);
    if (strcmp(encoded, "YWJj")) return 4;
    if (apr_base64_decode(decoded, encoded) != 3 || memcmp(decoded, "abc", 3)) return 5;
    parser = apr_xml_parser_create(pool);
    if (!parser || apr_xml_parser_feed(parser, xml, strlen(xml)) != APR_SUCCESS) return 7;
    if (apr_xml_parser_done(parser, &document) != APR_SUCCESS || !document || !document->root) return 8;
    if (strcmp(document->root->name, "sdk")) return 9;
#ifdef SDK_SHARED
    if (strncmp(ap_get_server_description(), "Apache/2.4.69", sizeof("Apache/2.4.69") - 1)) return 6;
    printf("Apache runtime: %s\n", ap_get_server_description());
#endif
    printf("APR %s; APR-util %s; pool/string/base64/XML operations passed\n", apr_version_string(), apu_version_string());
    apr_pool_destroy(pool);
    apr_terminate();
    return 0;
}
