#include "../../net-snmp/agent/mibgroup/mibII/vacm_vars.c"
#include <windows.h>
int main(int argc, char **argv) {
    unsigned char *group = NULL, *context = NULL;
    size_t glen, clen;
    int model, level;
    oid valid[] = {1, 'g', 1, 'c', 3, 1};
    SYSTEM_INFO system;
    unsigned char *memory;
    oid *malformed;
    DWORD protection;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (access_parse_oid(valid, 6, &group, &glen, &context, &clen, &model, &level) != 0) return 2;
    if (glen != 1 || clen != 1 || strcmp((char*)group,"g") || strcmp((char*)context,"c") || model != 3 || level != 1) return 3;
    free(group); free(context);
    if (access_parse_oid(NULL, 0, &group, &glen, &context, &clen, &model, &level) != 1) return 4;
    GetSystemInfo(&system);
    memory = VirtualAlloc(NULL, system.dwPageSize * 2, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!memory || !VirtualProtect(memory + system.dwPageSize, system.dwPageSize, PAGE_NOACCESS, &protection)) return 5;
    malformed = (oid*)(memory + system.dwPageSize - sizeof(oid));
    malformed[0] = 32;
    if (access_parse_oid(malformed, 1, &group, &glen, &context, &clen, &model, &level) != 1) return 6;
    VirtualFree(memory, 0, MEM_RELEASE);
    puts("PASS: valid VACM indexes decode; empty and oversized group indexes rejected before read");
    return 0;
}
