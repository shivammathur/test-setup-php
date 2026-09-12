#include "../../net-snmp/agent/mibgroup/agent/nsLogging.c"
#include <windows.h>
int main(int argc, char **argv) {
    netsnmp_request_info request;
    netsnmp_agent_request_info info;
    netsnmp_table_request_info table;
    int modes[] = {MODE_GET, MODE_SET_RESERVE1, MODE_SET_FREE, MODE_SET_UNDO};
    int i, missing;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    for (i = 0; i < 4; ++i) {
        for (missing = 0; missing < 2; ++missing) {
            memset(&request, 0, sizeof(request));
            memset(&info, 0, sizeof(info));
            memset(&table, 0, sizeof(table));
            info.mode = modes[i];
            table.colnum = 5;
            if (missing) netsnmp_request_add_list_data(&request,
                netsnmp_create_data_list(TABLE_HANDLER_NAME, &table, NULL));
            if (handle_nsLoggingTable(NULL, NULL, &info, &request) != SNMP_ERR_NOERROR) return 1;
            netsnmp_free_request_data_sets(&request);
        }
    }
    puts("PASS: logging table missing metadata/indexes in GET, RESERVE1, FREE and UNDO");
    return 0;
}
