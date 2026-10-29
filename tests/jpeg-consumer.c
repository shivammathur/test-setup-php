#include <stdio.h>
#include <stdlib.h>
#include <jpeglib.h>

#if JPEG_LIB_VERSION != EXPECT_JPEG_ABI
#error Unexpected JPEG ABI
#endif
#if LIBJPEG_TURBO_VERSION_NUMBER != 3002001
#error Unexpected libjpeg-turbo version
#endif

int main(void)
{
  struct jpeg_compress_struct enc = {0};
  struct jpeg_decompress_struct dec = {0};
  struct jpeg_error_mgr enc_error, dec_error;
  unsigned char *encoded = NULL;
  unsigned long encoded_size = 0;
  JSAMPLE pixels[16 * 3];
  JSAMPROW row = pixels;
  int x;
  for (x = 0; x < 16; x++) {
    pixels[3 * x] = 240;
    pixels[3 * x + 1] = 32;
    pixels[3 * x + 2] = 16;
  }
  enc.err = jpeg_std_error(&enc_error);
  jpeg_create_compress(&enc);
  jpeg_mem_dest(&enc, &encoded, &encoded_size);
  enc.image_width = 16;
  enc.image_height = 16;
  enc.input_components = 3;
  enc.in_color_space = JCS_RGB;
  jpeg_set_defaults(&enc);
  jpeg_set_quality(&enc, 95, TRUE);
  jpeg_start_compress(&enc, TRUE);
  while (enc.next_scanline < enc.image_height)
    if (jpeg_write_scanlines(&enc, &row, 1) != 1) return 1;
  jpeg_finish_compress(&enc);
  jpeg_destroy_compress(&enc);
  if (!encoded || encoded_size == 0) return 2;

  dec.err = jpeg_std_error(&dec_error);
  jpeg_create_decompress(&dec);
  jpeg_mem_src(&dec, encoded, encoded_size);
  if (jpeg_read_header(&dec, TRUE) != JPEG_HEADER_OK) return 3;
  dec.out_color_space = JCS_RGB;
  if (!jpeg_start_decompress(&dec)) return 4;
  if (dec.output_width != 16 || dec.output_height != 16 || dec.output_components != 3) return 5;
  while (dec.output_scanline < dec.output_height) {
    if (jpeg_read_scanlines(&dec, &row, 1) != 1) return 6;
    for (x = 0; x < 16; x++) {
      if (abs((int)pixels[3 * x] - 240) > 3 ||
          abs((int)pixels[3 * x + 1] - 32) > 3 ||
          abs((int)pixels[3 * x + 2] - 16) > 3) return 7;
    }
  }
  if (!jpeg_finish_decompress(&dec)) return 8;
  jpeg_destroy_decompress(&dec);
  free(encoded);
  printf("libjpeg-turbo 3.2.1, JPEG ABI %d: installed static library round-trip passed (%lu bytes)\n", JPEG_LIB_VERSION, encoded_size);
  return 0;
}
