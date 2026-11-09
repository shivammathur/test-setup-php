#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SAMPLES 1000
#define HANDOFFS 200
#define BYTES ((SIZE_T)128 * 1024 * 1024)
static LARGE_INTEGER frequency;
static double samples[7][SAMPLES];
static HANDLE mutex_handle, start_event, ready_event, done_event;
static volatile LONG first_owner;

static void require(int ok, const char *operation) {
    if (!ok) { fprintf(stderr, "%s failed: %lu\n", operation, GetLastError()); exit(2); }
}
static LONGLONG now(void) { LARGE_INTEGER t; QueryPerformanceCounter(&t); return t.QuadPart; }
static double elapsed(LONGLONG begin) { return (double)(now() - begin) * 1000000.0 / (double)frequency.QuadPart; }
static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static void emit(const char *name, double *values, int count) {
    qsort(values, (size_t)count, sizeof(double), compare_double);
    printf("\"%s\":{\"min_us\":%.3f,\"median_us\":%.3f,\"p95_us\":%.3f,\"max_us\":%.3f}",
        name, values[0], values[count / 2], values[(count * 95) / 100], values[count - 1]);
}
static DWORD WINAPI waiter(LPVOID unused) {
    int i;
    (void)unused;
    for (i = 0; i < HANDOFFS; i++) {
        require(WaitForSingleObject(start_event, INFINITE) == WAIT_OBJECT_0, "wait start");
        require(SetEvent(ready_event), "signal ready");
        require(WaitForSingleObject(mutex_handle, INFINITE) == WAIT_OBJECT_0, "peer wait mutex");
        InterlockedCompareExchange(&first_owner, 2, 0);
        require(ReleaseMutex(mutex_handle), "peer release mutex");
        require(SetEvent(done_event), "signal done");
    }
    return 0;
}
int main(void) {
    const char *names[] = {"create_mapping", "creator_map", "creator_protect", "peer_open_and_header", "peer_query", "peer_map", "peer_protect"};
    void *addresses[] = {(void *)(uintptr_t)0x20000000, (void *)(uintptr_t)0x21000000, (void *)(uintptr_t)0x30000000, (void *)(uintptr_t)0x31000000, (void *)(uintptr_t)0x50000000};
    char name[96];
    int i, j, parent_wins = 0, peer_wins = 0;
    double handoff[HANDOFFS];
    HANDLE thread;
    require(QueryPerformanceFrequency(&frequency), "QPC frequency");
    for (i = 0; i < SAMPLES; i++) {
        HANDLE mapping, opened;
        void *view = NULL, *header, *base, *reattached;
        DWORD old;
        MEMORY_BASIC_INFORMATION info;
        LONGLONG t;
        sprintf_s(name, sizeof(name), "Local\\php-memory-probe-%lu-%d", GetCurrentProcessId(), i);
        t = now();
        mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_EXECUTE_READWRITE | SEC_COMMIT, 0, (DWORD)BYTES, name);
        samples[0][i] = elapsed(t); require(mapping != NULL, "create mapping");
        t = now();
        for (j = 0; j < (int)(sizeof(addresses) / sizeof(addresses[0])); j++) {
            view = MapViewOfFileEx(mapping, FILE_MAP_ALL_ACCESS | FILE_MAP_EXECUTE, 0, 0, 0, addresses[j]);
            if (view) break;
        }
        samples[1][i] = elapsed(t); require(view != NULL, "creator map");
        t = now(); require(VirtualProtect(view, BYTES, PAGE_READWRITE, &old), "creator protect"); samples[2][i] = elapsed(t);
        ((void **)view)[0] = view; ((void **)view)[1] = (void *)(uintptr_t)1;
        base = view; require(UnmapViewOfFile(view), "creator unmap");
        t = now();
        opened = OpenFileMappingA(FILE_MAP_READ | FILE_MAP_WRITE | FILE_MAP_EXECUTE, FALSE, name);
        require(opened != NULL, "peer open");
        header = MapViewOfFileEx(opened, FILE_MAP_ALL_ACCESS, 0, 0, 2 * sizeof(void *), NULL);
        require(header != NULL && ((void **)header)[0] == base, "peer header");
        require(UnmapViewOfFile(header), "peer header unmap"); samples[3][i] = elapsed(t);
        t = now(); require(VirtualQuery(base, &info, sizeof(info)) != 0 && info.State == MEM_FREE && info.RegionSize >= BYTES, "peer query"); samples[4][i] = elapsed(t);
        t = now(); reattached = MapViewOfFileEx(opened, FILE_MAP_ALL_ACCESS | FILE_MAP_EXECUTE, 0, 0, 0, base);
        samples[5][i] = elapsed(t); require(reattached != NULL, "peer map");
        t = now(); require(VirtualProtect(reattached, BYTES, PAGE_READWRITE, &old), "peer protect"); samples[6][i] = elapsed(t);
        require(UnmapViewOfFile(reattached), "peer unmap"); CloseHandle(opened); CloseHandle(mapping);
    }
    mutex_handle = CreateMutexW(NULL, TRUE, NULL);
    start_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    ready_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    done_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    require(mutex_handle != NULL && start_event != NULL && ready_event != NULL && done_event != NULL, "create synchronization objects");
    thread = CreateThread(NULL, 0, waiter, NULL, 0, NULL); require(thread != NULL, "create waiter");
    for (i = 0; i < HANDOFFS; i++) {
        LONGLONG t;
        first_owner = 0;
        require(SetEvent(start_event), "signal start");
        require(WaitForSingleObject(ready_event, INFINITE) == WAIT_OBJECT_0, "wait ready");
        Sleep(1); /* Give the peer time to queue; no delay between release and reacquire. */
        t = now();
        require(ReleaseMutex(mutex_handle), "parent release mutex");
        require(WaitForSingleObject(mutex_handle, INFINITE) == WAIT_OBJECT_0, "parent reacquire mutex");
        handoff[i] = elapsed(t);
        if (InterlockedCompareExchange(&first_owner, 1, 0) == 0) parent_wins++; else peer_wins++;
        require(ReleaseMutex(mutex_handle), "parent final release");
        require(WaitForSingleObject(done_event, INFINITE) == WAIT_OBJECT_0, "wait done");
        require(WaitForSingleObject(mutex_handle, INFINITE) == WAIT_OBJECT_0, "parent reset mutex");
    }
    ReleaseMutex(mutex_handle); WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread); CloseHandle(mutex_handle); CloseHandle(start_event); CloseHandle(ready_event); CloseHandle(done_event);
    printf("{\"samples\":%d,\"mapping_bytes\":%llu,\"bits\":%u,\"qpc_frequency\":%lld,\"metrics\":{", SAMPLES, (unsigned long long)BYTES, (unsigned)(sizeof(void *) * 8), frequency.QuadPart);
    for (i = 0; i < 7; i++) { if (i) putchar(','); emit(names[i], samples[i], SAMPLES); }
    printf("},\"mutex_handoff\":{\"parent_first\":%d,\"peer_first\":%d,", parent_wins, peer_wins);
    emit("release_reacquire", handoff, HANDOFFS); puts("}}");
    return 0;
}
