#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <png.h>

#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(int argc, char **argv)
{
    png_image image;
    unsigned char source[7 * 5 * 4], decoded[sizeof source];
    unsigned int i;
    REQUIRE(png_access_version_number() == 10659);
    REQUIRE(strcmp(png_get_libpng_ver(NULL), "1.6.59") == 0);
    if (argc == 2) {
        void *pixels;
        memset(&image, 0, sizeof image);
        image.version = PNG_IMAGE_VERSION;
        REQUIRE(png_image_begin_read_from_file(&image, argv[1]));
        REQUIRE(image.width > 0 && image.height > 0);
        image.format = PNG_FORMAT_RGBA;
        pixels = malloc(PNG_IMAGE_SIZE(image));
        REQUIRE(pixels != NULL);
        REQUIRE(png_image_finish_read(&image, NULL, pixels, 0, NULL));
        printf("Decoded %s: %u x %u with libpng %s\n", argv[1], image.width, image.height, PNG_LIBPNG_VER_STRING);
        free(pixels);
        png_image_free(&image);
        return 0;
    }
    for (i = 0; i < sizeof source; ++i) source[i] = (unsigned char)(i * 29U);
    memset(&image, 0, sizeof image);
    image.version = PNG_IMAGE_VERSION;
    image.width = 7; image.height = 5; image.format = PNG_FORMAT_RGBA;
    REQUIRE(png_image_write_to_file(&image, "roundtrip.png", 0, source, 0, NULL));
    memset(&image, 0, sizeof image);
    image.version = PNG_IMAGE_VERSION;
    REQUIRE(png_image_begin_read_from_file(&image, "roundtrip.png"));
    REQUIRE(image.width == 7 && image.height == 5);
    image.format = PNG_FORMAT_RGBA;
    REQUIRE(png_image_finish_read(&image, NULL, decoded, 0, NULL));
    REQUIRE(memcmp(source, decoded, sizeof source) == 0);
    png_image_free(&image);
    puts("PASS libpng 1.6.59: exact RGBA encode/decode roundtrip");
    return 0;
}
