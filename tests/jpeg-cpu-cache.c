#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"
#include "jsimdconst.h"
extern unsigned int jpeg_simd_cpu_support(void);
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
int main(void) {
    HANDLE threads[8];LARGE_INTEGER frequency,start,end;unsigned int mask;DWORD result;int i;
    double cpu_query_us;
    _putenv_s("JSIMD_FORCENONE","");_putenv_s("JSIMD_FORCESSE2","");
    QueryPerformanceFrequency(&frequency);QueryPerformanceCounter(&start);
    for(i=0;i<5000;i++)jpeg_simd_cpu_support();
    QueryPerformanceCounter(&end);cpu_query_us=(double)(end.QuadPart-start.QuadPart)/frequency.QuadPart*1e6/5000;
    gate=CreateEvent(NULL,TRUE,FALSE,NULL);if(!gate)return 21;
    for(i=0;i<8;i++){threads[i]=CreateThread(NULL,0,worker,NULL,0,NULL);if(!threads[i])return 22;}
    SetEvent(gate);
    if(WaitForMultipleObjects(8,threads,TRUE,60000)!=WAIT_OBJECT_0)return 23;
    for(i=0;i<8;i++){if(!GetExitCodeThread(threads[i],&result)||result)return 24;CloseHandle(threads[i]);}CloseHandle(gate);
    mask=roundtrip(JSIMD_UNDEFINED);
    _putenv_s("JSIMD_FORCENONE","1");roundtrip(0);
    _putenv_s("JSIMD_FORCENONE","");roundtrip(mask);
#if defined(_M_IX86) || defined(_M_X64)
    _putenv_s("JSIMD_FORCESSE2","1");roundtrip(mask & (JSIMD_SSE2|JSIMD_SSE));
    _putenv_s("JSIMD_FORCESSE2","");roundtrip(mask);
#endif
    printf("{\"passed\":true,\"threads\":8,\"concurrent_roundtrips\":800,\"simd_mask\":%u,\"cpu_query_microseconds\":%.6f,\"environment_changes_preserved\":true}\n",mask,cpu_query_us);
    return 0;
}
