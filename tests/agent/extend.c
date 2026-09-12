#include "../../net-snmp/agent/mibgroup/agent/extend.c"
#include <windows.h>

int
main(void)
{
    oid name[] = { 1, 3, 6, 1, 4, 1, 8072, 1, 3, 2, 2, 1, 2 };
    netsnmp_variable_list varbind;
    netsnmp_request_info request;
    netsnmp_agent_request_info info;
    int result;

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    memset(&varbind, 0, sizeof(varbind));
    memset(&request, 0, sizeof(request));
    memset(&info, 0, sizeof(info));
    varbind.name = name;
    varbind.name_length = OID_LENGTH(name);
    varbind.type = ASN_OCTET_STR;
    request.requestvb = &varbind;
    info.mode = MODE_SET_RESERVE1;

    result = handle_nsExtendConfigTable(NULL, NULL, &info, &request);
    printf("extend SET result=%d status=%d processed=%d\n",
           result, request.status, request.processed);
    if (result != SNMP_ERR_GENERR || request.status != SNMP_ERR_GENERR ||
        request.processed != 1)
        return 1;

    puts("PASS: extend MIB SET handling is disabled while the handler remains available");
    return 0;
}
