#include <net-snmp/net-snmp-config.h>
#include <net-snmp/net-snmp-includes.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    oid actual[MAX_OID_LEN];
    oid expected[] = { 1, 3, 6, 1, 4, 1, 8072, 9999, 1 };
    size_t length = MAX_OID_LEN;

    if (argc != 2) {
        fprintf(stderr, "Usage: mib-index MIB_DIRECTORY\n");
        return 2;
    }
    init_snmp("mib-index-regression");
    if (add_mibdir(argv[1]) < 1 || read_module("SECURITY-TEST-MIB") == NULL ||
        !read_objid("SECURITY-TEST-MIB::testLeaf", actual, &length) ||
        snmp_oid_compare(actual, length, expected,
                         sizeof(expected) / sizeof(expected[0])) != 0) {
        fprintf(stderr, "MIB directory scan or OID resolution failed\n");
        return 1;
    }
    /* Repeated scans must still work after removing the persistent cache. */
    if (add_mibdir(argv[1]) < 1) {
        fprintf(stderr, "Repeated MIB directory scan failed\n");
        return 1;
    }
    snmp_shutdown("mib-index-regression");
    puts("MIB scanning and OID resolution passed");
    return 0;
}
