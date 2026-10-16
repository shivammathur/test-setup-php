#include <windows.h>
#include <stdlib.h>

/* Return success only if the child can perform I/O on each requested NUL handle. */
int main(int argc, char **argv)
{
    DWORD ids[] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
    int first, last, i;
    if (argc != 2) return 99;
    first = atoi(argv[1]);
    last = first;
    if (first == 3) { first = 0; last = 2; }
    for (i = first; i <= last; i++) {
        HANDLE h = GetStdHandle(ids[i]);
        DWORD transferred = 123;
        char buffer[] = "test";
        if (h == NULL || h == INVALID_HANDLE_VALUE) return 10 + i;
        if (GetFileType(h) != FILE_TYPE_CHAR) return 20 + i;
        if (i == 0) {
            if (!ReadFile(h, buffer, 1, &transferred, NULL)) return 30 + i;
            if (transferred != 0) return 40 + i;
        } else {
            if (!WriteFile(h, buffer, 4, &transferred, NULL)) return 30 + i;
            if (transferred != 4) return 40 + i;
        }
    }
    return 0;
}
