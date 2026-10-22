#include <jxl/encode.h>
#include <jxl/decode.h>
#include <jxl/color_encoding.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed line %d: %s\n",__LINE__,#x); return 1; } } while(0)

int main(void) {
  unsigned char pixels[32*16*3], decoded[sizeof(pixels)], data[65536], box[4096], meta[1024];
  size_t i, avail=sizeof(data), size, box_used=0;
  unsigned char *next=data;
  int image_done=0, box_seen=0, compressed_seen=0, box_active=0;
  JxlEncoder *enc=JxlEncoderCreate(NULL);
  JxlDecoder *dec=JxlDecoderCreate(NULL);
  JxlBasicInfo info;
  JxlColorEncoding color;
  JxlPixelFormat format={3,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};
  JxlEncoderFrameSettings *settings;
  CHECK(enc && dec && JxlEncoderVersion()==12000 && JxlDecoderVersion()==12000);
  for(i=0;i<sizeof(pixels);i++) pixels[i]=(unsigned char)(i*7%251);
  for(i=0;i<sizeof(meta);i++) meta[i]=(unsigned char)(i%29+65);
  JxlEncoderInitBasicInfo(&info);
  info.xsize=32; info.ysize=16; info.bits_per_sample=8; info.uses_original_profile=JXL_TRUE;
  CHECK(JxlEncoderSetBasicInfo(enc,&info)==JXL_ENC_SUCCESS);
  JxlColorEncodingSetToSRGB(&color,JXL_FALSE);
  CHECK(JxlEncoderSetColorEncoding(enc,&color)==JXL_ENC_SUCCESS);
  CHECK(JxlEncoderUseBoxes(enc)==JXL_ENC_SUCCESS);
  CHECK(JxlEncoderAddBox(enc,"xml ",meta,sizeof(meta),JXL_TRUE)==JXL_ENC_SUCCESS);
  settings=JxlEncoderFrameSettingsCreate(enc,NULL);
  CHECK(settings && JxlEncoderSetFrameLossless(settings,JXL_TRUE)==JXL_ENC_SUCCESS);
  CHECK(JxlEncoderAddImageFrame(settings,&format,pixels,sizeof(pixels))==JXL_ENC_SUCCESS);
  JxlEncoderCloseInput(enc);
  CHECK(JxlEncoderProcessOutput(enc,&next,&avail)==JXL_ENC_SUCCESS);
  size=sizeof(data)-avail;
  CHECK(JxlDecoderSubscribeEvents(dec,JXL_DEC_BASIC_INFO|JXL_DEC_FULL_IMAGE|JXL_DEC_BOX)==JXL_DEC_SUCCESS);
  CHECK(JxlDecoderSetDecompressBoxes(dec,JXL_TRUE)==JXL_DEC_SUCCESS);
  CHECK(JxlDecoderSetInput(dec,data,size)==JXL_DEC_SUCCESS);
  JxlDecoderCloseInput(dec);
  for(i=0;i<100;i++) {
    JxlDecoderStatus status=JxlDecoderProcessInput(dec);
    if(status==JXL_DEC_BOX || status==JXL_DEC_SUCCESS) {
      if(box_active) { box_used=sizeof(box)-JxlDecoderReleaseBoxBuffer(dec); box_active=0; }
    }
    if(status==JXL_DEC_SUCCESS) break;
    if(status==JXL_DEC_BASIC_INFO) {
      CHECK(JxlDecoderGetBasicInfo(dec,&info)==JXL_DEC_SUCCESS && info.xsize==32 && info.ysize==16);
    } else if(status==JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      CHECK(JxlDecoderSetImageOutBuffer(dec,&format,decoded,sizeof(decoded))==JXL_DEC_SUCCESS);
    } else if(status==JXL_DEC_FULL_IMAGE) {
      image_done=1;
    } else if(status==JXL_DEC_BOX) {
      JxlBoxType raw,type;
      CHECK(JxlDecoderGetBoxType(dec,raw,JXL_FALSE)==JXL_DEC_SUCCESS);
      CHECK(JxlDecoderGetBoxType(dec,type,JXL_TRUE)==JXL_DEC_SUCCESS);
      if(memcmp(type,"xml ",4)==0) {
        CHECK(!box_seen); box_seen=1; compressed_seen=memcmp(raw,"brob",4)==0;
        CHECK(JxlDecoderSetBoxBuffer(dec,box,sizeof(box))==JXL_DEC_SUCCESS); box_active=1;
      }
    } else CHECK(0);
  }
  CHECK(i<100 && image_done && box_seen && compressed_seen);
  CHECK(memcmp(pixels,decoded,sizeof(pixels))==0);
  CHECK(box_used==sizeof(meta) && memcmp(meta,box,sizeof(meta))==0);
  JxlEncoderDestroy(enc); JxlDecoderDestroy(dec);
  puts("{\"libjxlVersion\":\"0.12.0\",\"imageRoundtrip\":true,\"brotliBoxRoundtrip\":true,\"failures\":0}");
  return 0;
}
