#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zlib.h"

int main(void) {
    unsigned char input[65537], output[65537], compressed[70000];
    unsigned long state = 12345;
    int level, mode;
    const int windows[] = {-15, 15, 31};
    size_t i;
    gzFile file;
    for (i = 0; i < sizeof(input); ++i) {
        state = state * 1664525UL + 1013904223UL;
        input[i] = (unsigned char)(state >> 24);
    }
    if (strcmp(zlibVersion(), "1.3.2")) return 1;
    for (level = 0; level <= 9; ++level) {
        uLongf clen = sizeof(compressed), olen = sizeof(output);
        if (compress2(compressed, &clen, input, sizeof(input), level) != Z_OK) return 2;
        if (uncompress(output, &olen, compressed, clen) != Z_OK || olen != sizeof(input) || memcmp(input, output, olen)) return 3;
    }
    for (mode = 0; mode < 3; ++mode) {
        z_stream def = {0}, inf = {0};
        int window = windows[mode];
        if (deflateInit2(&def, 6, Z_DEFLATED, window, 8, Z_DEFAULT_STRATEGY) != Z_OK) return 4;
        def.next_in = input; def.avail_in = sizeof(input);
        def.next_out = compressed; def.avail_out = sizeof(compressed);
        if (deflate(&def, Z_FINISH) != Z_STREAM_END) return 5;
        inf.next_in = compressed; inf.avail_in = def.total_out;
        inf.next_out = output; inf.avail_out = sizeof(output);
        if (inflateInit2(&inf, window) != Z_OK || inflate(&inf, Z_FINISH) != Z_STREAM_END || inf.total_out != sizeof(input) || memcmp(input, output, sizeof(input))) return 6;
        deflateEnd(&def); inflateEnd(&inf);
    }
    file = gzopen("native-zlib.gz", "wb9");
    if (!file || gzwrite(file, input, sizeof(input)) != sizeof(input) || gzclose(file) != Z_OK) return 7;
    file = gzopen("native-zlib.gz", "rb");
    if (!file || gzread(file, output, sizeof(output)) != sizeof(input) || memcmp(input, output, sizeof(input)) || gzclose(file) != Z_OK) return 8;
    remove("native-zlib.gz");
    puts("zlib 1.3.2: static compression levels, stream formats and gzip file round trips passed");
    return 0;
}
