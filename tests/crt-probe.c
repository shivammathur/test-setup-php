#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
static LARGE_INTEGER frequency;
static double stamp(void) { LARGE_INTEGER t; QueryPerformanceCounter(&t); return (double)t.QuadPart / frequency.QuadPart; }
static int narrow(const char *name) { char value[2] = {0}; size_t n; return !getenv_s(&n, value, 2, name) && !strcmp(value, "1"); }
static int wide(const wchar_t *name) { wchar_t value[2] = {0}; size_t n; return !_wgetenv_s(&n, value, 2, name) && !wcscmp(value, L"1"); }
int main(void) {
  const char *keys[] = {"JSIMD_FORCESSE2", "JSIMD_FORCESSE", "JSIMD_FORCEMMX", "JSIMD_FORCE3DNOW", "JSIMD_FORCENONE", "JSIMD_NOHUFFENC"};
  const wchar_t *wkeys[] = {L"JSIMD_FORCESSE2", L"JSIMD_FORCESSE", L"JSIMD_FORCEMMX", L"JSIMD_FORCE3DNOW", L"JSIMD_FORCENONE", L"JSIMD_NOHUFFENC"};
  double start, ntime, wtime; int i, k, cn, cw, on, ow, un, uw, fn, fw; volatile int sink = 0;
  QueryPerformanceFrequency(&frequency);
  for (k=0;k<6;k++) _putenv_s(keys[k], "");
  for (k=0;k<6;k++) sink += wide(wkeys[k]);
  start=stamp(); for(i=0;i<10000;i++)for(k=0;k<6;k++)sink += narrow(keys[k]); ntime=(stamp()-start)*100;
  start=stamp(); for(i=0;i<10000;i++)for(k=0;k<6;k++)sink += wide(wkeys[k]); wtime=(stamp()-start)*100;
  _putenv_s("JSIMD_FORCENONE", "1"); SetEnvironmentVariableA("JSIMD_FORCENONE", NULL); cn=narrow(keys[4]); cw=wide(wkeys[4]);
  _putenv_s("JSIMD_FORCENONE", ""); SetEnvironmentVariableA("JSIMD_FORCENONE", "1"); on=narrow(keys[4]); ow=wide(wkeys[4]);
  _wputenv_s(L"JSIMD_FORCENONE", L"\xff11"); un=narrow(keys[4]); uw=wide(wkeys[4]);
  _wputenv_s(L"JSIMD_FORCENONE", L""); _wputenv_s(L"\xff2aSIMD_FORCENONE", L"1"); fn=narrow(keys[4]); fw=wide(wkeys[4]);
  printf("{\"bits\":%u,\"narrow_six_us\":%.6f,\"wide_six_us\":%.6f,\"crt_only\":[%d,%d],\"os_only\":[%d,%d],\"fullwidth_value\":[%d,%d],\"fullwidth_name\":[%d,%d]}\n", (unsigned)(sizeof(void*)*8),ntime,wtime,cn,cw,on,ow,un,uw,fn,fw);
  return sink == -1;
}
