#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H

int main(int argc, char **argv)
{
  FT_Library library;
  FT_Face face;
  FT_Error error;
  FT_Int major, minor, patch;
  const char *fonts[] = { "arial.ttf", "times.ttf", "segoeui.ttf", "comic.ttf", "calibri.ttf" };
  const unsigned sizes[] = { 8, 12, 16, 18, 40, 72 };
  char path[1024], version[64];
  unsigned f, s, c, y, x, count = 0, found = 0;
  FILE *csv;
  if(argc != 4 || !getenv("WINDIR")) return 2;
  if(FT_Init_FreeType(&library)) return 3;
  FT_Library_Version(library, &major, &minor, &patch);
  snprintf(version, sizeof(version), "%d.%d.%d", major, minor, patch);
  if(strcmp(version, argv[3])) { fprintf(stderr, "Wrong FreeType version: %s\n", version); return 4; }
  csv = fopen(argv[1], "w");
  if(!csv) return 5;
  fprintf(csv, "font,size,char,advance_x,advance_y,left,top,width,rows,bitmap_hash\n");
  for(f = 0; f < sizeof(fonts) / sizeof(fonts[0]); ++f) {
    snprintf(path, sizeof(path), "%s/Fonts/%s", getenv("WINDIR"), fonts[f]);
    error = FT_New_Face(library, path, 0, &face);
    if(error) continue;
    ++found;
    for(s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
      if(FT_Set_Pixel_Sizes(face, 0, sizes[s])) return 6;
      for(c = 32; c < 256; ++c) {
        uint64_t hash = UINT64_C(14695981039346656037);
        FT_Bitmap *bitmap;
        error = FT_Load_Char(face, c, FT_LOAD_RENDER);
        if(error) { fprintf(stderr, "%s %u %u: %d\n", fonts[f], sizes[s], c, error); return 7; }
        bitmap = &face->glyph->bitmap;
        if(bitmap->pitch < 0 || bitmap->width > 4096 || bitmap->rows > 4096) return 8;
        for(y = 0; y < bitmap->rows; ++y)
          for(x = 0; x < bitmap->width; ++x) {
            hash ^= bitmap->buffer[y * bitmap->pitch + x];
            hash *= UINT64_C(1099511628211);
          }
        fprintf(csv, "%s,%u,%u,%ld,%ld,%d,%d,%u,%u,%llu\n", fonts[f], sizes[s], c,
                (long)face->glyph->advance.x, (long)face->glyph->advance.y,
                face->glyph->bitmap_left, face->glyph->bitmap_top, bitmap->width,
                bitmap->rows, (unsigned long long)hash);
        ++count;
      }
    }
    FT_Done_Face(face);
  }
  fclose(csv);
  if(found < 3) { fprintf(stderr, "Only %u reference fonts available\n", found); return 9; }
  if(strcmp(argv[3], "2.15.0") == 0) {
    FT_Fixed coordinates[64];
    FT_MM_Var *variation = NULL;
    unsigned i;
    if(FT_New_Face(library, argv[2], 0, &face)) return 10;
    if(FT_Get_MM_Var(face, &variation) || !variation || variation->num_axis != 1) return 11;
    coordinates[0] = 65536;
    if(FT_Set_Var_Design_Coordinates(face, 1, coordinates)) return 12;
    for(i = 0; i < 64; ++i) coordinates[i] = 0x123456;
    if(FT_Get_Var_Design_Coordinates(face, 64, coordinates)) return 13;
    if(coordinates[0] != 65536) return 14;
    for(i = 1; i < 64; ++i) if(coordinates[i] != 0) return 15;
    FT_Done_MM_Var(library, variation);
    FT_Done_Face(face);
  }
  FT_Done_FreeType(library);
  printf("FreeType %s: %u fonts, %u rendered glyphs; variation bounds passed where applicable\n", version, found, count);
  return 0;
}
