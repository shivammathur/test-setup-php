#define _CRT_SECURE_NO_WARNINGS
#define _LARGEFILE64_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <windows.h>
#include <winioctl.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s failed at %d\n", #x, __LINE__); return 1; } } while (0)
int main(void) {
    const char *path = "zlib-sparse-offsets.bin";
    const z_off64_t offset = ((z_off64_t)3 << 30) + 123;
    HANDLE h; LARGE_INTEGER pos; DWORD size, unused;
    char marker[] = "zlib-1.4-large-offset", actual[sizeof(marker)];
    gzFile f;
#ifdef _FILE_OFFSET_BITS
    CHECK(_FILE_OFFSET_BITS == 64);
#else
    CHECK(sizeof(z_off_t) == 4);
#endif
    CHECK(sizeof(z_off64_t) == 8);
    h = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    CHECK(h != INVALID_HANDLE_VALUE);
    CHECK(DeviceIoControl(h, FSCTL_SET_SPARSE, NULL, 0, NULL, 0, &unused, NULL));
    pos.QuadPart = offset;
    CHECK(SetFilePointerEx(h, pos, NULL, FILE_BEGIN));
    CHECK(WriteFile(h, marker, sizeof(marker), &size, NULL) && size == sizeof(marker));
    CHECK(CloseHandle(h));
    f = gzopen64(path, "rb"); CHECK(f != NULL);
    CHECK(gzdirect(f) == 1);
    CHECK(gzseek64(f, offset, SEEK_SET) == offset);
    CHECK(gztell64(f) == offset);
    CHECK(gzread(f, actual, sizeof(actual)) == sizeof(actual));
    CHECK(memcmp(marker, actual, sizeof(marker)) == 0);
    CHECK(gztell64(f) == offset + sizeof(marker));
    CHECK(gzclose(f) == Z_OK);
    f = gzopen(path, "rb"); CHECK(f != NULL);
    CHECK(gzdirect(f) == 1);
#ifdef _FILE_OFFSET_BITS
    CHECK(gzseek(f, offset, SEEK_SET) == offset);
    CHECK(gztell(f) == offset);
#else
    CHECK(gzseek(f, 123, SEEK_SET) == 123);
    CHECK(gztell(f) == 123);
#endif
    CHECK(gzclose(f) == Z_OK);
    CHECK(remove(path) == 0);
    printf("zlib 1.4: default offset ABI and explicit/mapped 64-bit seek/tell/read passed\n");
    return 0;
}
