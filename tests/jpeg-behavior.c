#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"
#include "jsimdconst.h"
static HANDLE gate;
static unsigned int roundtrip(unsigned int expected) {
    struct jpeg_compress_struct c; struct jpeg_decompress_struct d;
    struct jpeg_error_mgr ce,de; unsigned char pixels[64*64*3],decoded[64*64*3],*jpeg=NULL;
    unsigned long size=0; unsigned int actual; int i;
    memset(pixels,100,sizeof(pixels));
    c.err=jpeg_std_error(&ce);jpeg_create_compress(&c);jpeg_mem_dest(&c,&jpeg,&size);
    c.image_width=64;c.image_height=64;c.input_components=3;c.in_color_space=JCS_RGB;
    jpeg_set_defaults(&c);jpeg_set_quality(&c,90,TRUE);jpeg_start_compress(&c,TRUE);
    actual=c.master->simd_support;
    if ((expected==JSIMD_UNDEFINED && (actual==0 || actual==JSIMD_UNDEFINED)) ||
        (expected!=JSIMD_UNDEFINED && actual!=expected)) exit(10);
    while(c.next_scanline<c.image_height) { JSAMPROW row=pixels+c.next_scanline*64*3;jpeg_write_scanlines(&c,&row,1); }
    jpeg_finish_compress(&c);jpeg_destroy_compress(&c);
    d.err=jpeg_std_error(&de);jpeg_create_decompress(&d);jpeg_mem_src(&d,jpeg,size);
    if(jpeg_read_header(&d,TRUE)!=JPEG_HEADER_OK)exit(11);
    d.out_color_space=JCS_RGB;jpeg_start_decompress(&d);
    if(d.output_width!=64 || d.output_height!=64 || d.output_components!=3 || d.master->simd_support!=actual)exit(12);
    while(d.output_scanline<d.output_height) { JSAMPROW row=decoded+d.output_scanline*64*3;jpeg_read_scanlines(&d,&row,1); }
    jpeg_finish_decompress(&d);jpeg_destroy_decompress(&d);free(jpeg);
    for(i=0;i<(int)sizeof(decoded);i++)if(abs(decoded[i]-100)>2)exit(13);
    return actual;
}
static DWORD WINAPI worker(LPVOID unused) {
    int i;(void)unused;
    if(WaitForSingleObject(gate,30000)!=WAIT_OBJECT_0)return 20;
    for(i=0;i<100;i++)roundtrip(JSIMD_UNDEFINED);
    return 0;
}
static long memory_setting(int explicit_api) {
    struct jpeg_compress_struct c;struct jpeg_error_mgr e;long result;
    c.err=jpeg_std_error(&e);jpeg_create_compress(&c);
    if(explicit_api)c.mem->max_memory_to_use=2345000L;
    result=c.mem->max_memory_to_use;jpeg_destroy_compress(&c);return result;
}
static unsigned int huffman_setting(void) {
    struct jpeg_compress_struct c;struct jpeg_error_mgr e;unsigned char *data=NULL;
    unsigned long size=0;unsigned int result;
    c.err=jpeg_std_error(&e);jpeg_create_compress(&c);jpeg_mem_dest(&c,&data,&size);
    c.image_width=64;c.image_height=64;c.input_components=3;c.in_color_space=JCS_RGB;
    jpeg_set_defaults(&c);jpeg_start_compress(&c,TRUE);
    result=c.master->simd_huffman;jpeg_abort_compress(&c);jpeg_destroy_compress(&c);free(data);return result;
}
int main(int argc,char **argv) {
    HANDLE threads[8];unsigned int mask,forced;DWORD result;int i,disabled;
    long memory_default,memory_env,memory_api;unsigned int huffman_default,huffman_env;
    const char *names[]={"JSIMD_FORCENONE","JSIMD_FORCESSE2","JSIMD_FORCESSE","JSIMD_FORCEMMX","JSIMD_FORCE3DNOW","JSIMD_NOHUFFENC","JPEGMEM"};
    if(argc!=2)return 1;disabled=!strcmp(argv[1],"no_getenv");
    for(i=0;i<7;i++)if(_putenv_s(names[i],""))return 2;
    gate=CreateEvent(NULL,TRUE,FALSE,NULL);if(!gate)return 21;
    for(i=0;i<8;i++){threads[i]=CreateThread(NULL,0,worker,NULL,0,NULL);if(!threads[i])return 22;}
    SetEvent(gate);
    if(WaitForMultipleObjects(8,threads,TRUE,60000)!=WAIT_OBJECT_0)return 23;
    for(i=0;i<8;i++){if(!GetExitCodeThread(threads[i],&result)||result)return 24;CloseHandle(threads[i]);}CloseHandle(gate);
    mask=roundtrip(JSIMD_UNDEFINED);
    _putenv_s("JSIMD_FORCENONE","1");forced=roundtrip(disabled?mask:0);
    _putenv_s("JSIMD_FORCENONE","");roundtrip(mask);
#if defined(_M_IX86) || defined(_M_X64)
    _putenv_s("JSIMD_FORCESSE2","1");roundtrip(disabled?mask:mask & (JSIMD_SSE2|JSIMD_SSE));
    _putenv_s("JSIMD_FORCESSE2","");roundtrip(mask);
#endif
    huffman_default=huffman_setting();_putenv_s("JSIMD_NOHUFFENC","1");huffman_env=huffman_setting();
    if(huffman_env!=(disabled?huffman_default:0))return 30;
    _putenv_s("JSIMD_NOHUFFENC","");
    memory_default=memory_setting(0);_putenv_s("JPEGMEM","1234");memory_env=memory_setting(0);memory_api=memory_setting(1);
    if(memory_env!=(disabled?memory_default:1234000L)||memory_api!=2345000L)return 31;
    _putenv_s("JPEGMEM","");
    printf("{\"passed\":true,\"no_getenv\":%s,\"concurrent_roundtrips\":800,\"simd_mask\":%u,\"forced_none_mask\":%u,\"huffman_default\":%u,\"huffman_env\":%u,\"memory_default\":%ld,\"memory_env\":%ld,\"memory_explicit_api\":%ld}\n",disabled?"true":"false",mask,forced,huffman_default,huffman_env,memory_default,memory_env,memory_api);
    return 0;
}
