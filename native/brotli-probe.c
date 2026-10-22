#include <brotli/decode.h>
#include <brotli/encode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #x); return 1; } } while (0)

int main(void) {
  const size_t sizes[] = {0, 1, 17, 1024, 65536};
  const int qualities[] = {0, 4, 11};
  unsigned char input[65536], compressed[70000], output[65568];
  size_t i, si, qi, cases = 0;
  CHECK(BrotliDecoderVersion() == 0x1002001);
  CHECK(BrotliEncoderVersion() == 0x1002001);
  CHECK(strcmp(BrotliDecoderErrorString(BROTLI_DECODER_ERROR_FORMAT_BLOCK_SWITCH), "_ERROR_FORMAT_BLOCK_SWITCH") == 0);
  for (i=0;i<sizeof(input);i++) input[i]=(unsigned char)((i*17+(i/113))%251);
  for (si=0;si<sizeof(sizes)/sizeof(sizes[0]);si++) {
    for (qi=0;qi<sizeof(qualities)/sizeof(qualities[0]);qi++) {
      size_t encoded=sizeof(compressed), decoded=sizeof(output);
      CHECK(BrotliEncoderCompress(qualities[qi], 22, BROTLI_MODE_GENERIC, sizes[si], input, &encoded, compressed));
      CHECK(BrotliDecoderDecompress(encoded, compressed, &decoded, output) == BROTLI_DECODER_RESULT_SUCCESS);
      CHECK(decoded == sizes[si] && memcmp(input, output, decoded) == 0);
      cases++;
      for (i=0;i<2;i++) {
        size_t offset=0, total=0, guard=0, available=0;
        const uint8_t *next=compressed;
        BrotliDecoderResult result=BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT;
        BrotliDecoderState *state=BrotliDecoderCreateInstance(NULL,NULL,NULL);
        CHECK(state);
        while (result != BROTLI_DECODER_RESULT_SUCCESS) {
          size_t out_size=17;
          uint8_t *out=output+total;
          CHECK(++guard<100000 && total+out_size<=sizeof(output));
          if (available==0 && offset<encoded) {
            available=i?encoded-offset:1;
            next=compressed+offset;
            offset+=available;
          }
          result=BrotliDecoderDecompressStream(state,&available,&next,&out_size,&out,NULL);
          total+=17-out_size;
          CHECK(result!=BROTLI_DECODER_RESULT_ERROR);
          CHECK(result!=BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT || available || offset<encoded);
        }
        CHECK(total==sizes[si] && memcmp(input,output,total)==0);
        BrotliDecoderDestroyInstance(state);
        cases++;
      }
      if (sizes[si]==65536 && qualities[qi]==4) {
        FILE *f=fopen("reports/payload.raw","wb"); CHECK(f); CHECK(fwrite(input,1,sizes[si],f)==sizes[si]); fclose(f);
        f=fopen("reports/payload.br","wb"); CHECK(f); CHECK(fwrite(compressed,1,encoded,f)==encoded); fclose(f);
        decoded=sizeof(output);
        CHECK(BrotliDecoderDecompress(encoded/2,compressed,&decoded,output)!=BROTLI_DECODER_RESULT_SUCCESS);
        cases++;
      }
    }
  }
  {
    size_t decoded=sizeof(output);
    memset(compressed,255,32);
    CHECK(BrotliDecoderDecompress(32,compressed,&decoded,output)==BROTLI_DECODER_RESULT_ERROR);
    cases++;
  }
  printf("{\"brotliVersion\":\"1.2.1\",\"cases\":%zu,\"failures\":0}\n",cases);
  return 0;
}
