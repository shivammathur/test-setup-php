#include <windows.h>
#include <stdint.h>
typedef void (__stdcall *callback_stdcall)(uintptr_t);
typedef void (__cdecl *callback_cdecl)(uintptr_t);
static volatile ULONG_PTR observed;
static void CALLBACK native_apc(ULONG_PTR value) { observed = value; }
__declspec(dllexport) unsigned int invoke_stdcall(callback_stdcall cb) {
    cb(123);
    return 321;
}
__declspec(dllexport) unsigned int invoke_cdecl(callback_cdecl cb) {
    cb(123);
    return 321;
}
__declspec(dllexport) unsigned int native_apc_control(void) {
    observed = 0;
    if (!QueueUserAPC(native_apc, GetCurrentThread(), 123)) return 0;
    SleepEx(0, TRUE);
    return (unsigned int)observed;
}
