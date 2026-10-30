#include <tiffio.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    enum { W = 640, H = 480 };
    unsigned char row[W * 3];
    TIFF *t;
    uint32_t width, height;
    int x, y;
    if (!TIFFIsCODECConfigured(COMPRESSION_JPEG)) return 1;
    t = TIFFOpen("jpeg-roundtrip.tif", "w");
    if (!t) return 2;
    if (!TIFFSetField(t, TIFFTAG_IMAGEWIDTH, W) ||
        !TIFFSetField(t, TIFFTAG_IMAGELENGTH, H) ||
        !TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 3) ||
        !TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 8) ||
        !TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG) ||
        !TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_YCBCR) ||
        !TIFFSetField(t, TIFFTAG_COMPRESSION, COMPRESSION_JPEG) ||
        !TIFFSetField(t, TIFFTAG_JPEGQUALITY, 95) ||
        !TIFFSetField(t, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB) ||
        !TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, 16)) return 3;
    for (x = 0; x < W; x++) { row[3*x] = 70; row[3*x+1] = 110; row[3*x+2] = 150; }
    for (y = 0; y < H; y++) if (TIFFWriteScanline(t, row, y, 0) < 0) return 4;
    TIFFClose(t);
    t = TIFFOpen("jpeg-roundtrip.tif", "r");
    if (!t || !TIFFGetField(t, TIFFTAG_IMAGEWIDTH, &width) ||
        !TIFFGetField(t, TIFFTAG_IMAGELENGTH, &height) || width != W || height != H ||
        !TIFFSetField(t, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB)) return 5;
    for (y = 0; y < H; y++) {
        if (TIFFReadScanline(t, row, y, 0) < 0) return 6;
        for (x = 0; x < W * 3; x++) if (abs((int)row[x] - (70 + 40 * (x % 3))) > 4) return 7;
    }
    TIFFClose(t);
    remove("jpeg-roundtrip.tif");
    puts("TIFF JPEG encode/decode and pixels passed");
    return 0;
}
