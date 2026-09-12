#include <net-snmp/net-snmp-config.h>
#include <net-snmp/net-snmp-includes.h>

int
main(void)
{
    netsnmp_pdu pdu;
    u_char malformed[] = {
        0xa2, 0x0c,
        0x02, 0x01, 0x01,
        0x02, 0x01, 0x00,
        0x02, 0x01, 0x00,
        0x30, 0x01, 0xff
    };
    size_t length = sizeof(malformed);
    int result;

    memset(&pdu, 0, sizeof(pdu));
    result = snmp_pdu_parse(&pdu, malformed, &length);
    if (result != -1)
        return 1;

#ifdef EXPECT_FIXED
    if (pdu.variables != NULL)
        return 2;
#else
    if (pdu.variables == NULL)
        return 3;
#endif

#ifdef EXPECT_FIXED
    puts("PASS: malformed varbind is rejected without attaching an incomplete variable");
#else
    puts("PASS negative control: malformed varbind leaves an incomplete variable attached");
#endif
    return 0;
}
