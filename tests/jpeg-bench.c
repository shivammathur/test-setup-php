#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>
#define STR_IMPL(x) #x
#define STR(x) STR_IMPL(x)
#ifdef _WIN32
#include <windows.h>
static double now(void) { LARGE_INTEGER f,t; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t); return (double)t.QuadPart/(double)f.QuadPart; }
#else
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
#endif
static unsigned char *encode(unsigned char *rgb,int w,int h,int q,int progressive,unsigned long *size) {
    struct jpeg_compress_struct c; struct jpeg_error_mgr e; unsigned char *out=NULL;
    c.err=jpeg_std_error(&e); jpeg_create_compress(&c); jpeg_mem_dest(&c,&out,size);
    c.image_width=w;c.image_height=h;c.input_components=3;c.in_color_space=JCS_RGB;
    jpeg_set_defaults(&c);jpeg_set_quality(&c,q,TRUE);if(progressive)jpeg_simple_progression(&c);
    jpeg_start_compress(&c,TRUE);
    while(c.next_scanline<c.image_height) { JSAMPROW row=rgb+(size_t)c.next_scanline*w*3; if(jpeg_write_scanlines(&c,&row,1)!=1)exit(10); }
    jpeg_finish_compress(&c);jpeg_destroy_compress(&c);return out;
}
static size_t decode(unsigned char *jpeg,unsigned long size,unsigned char *rgb,int w,int h) {
    struct jpeg_decompress_struct d;struct jpeg_error_mgr e;d.err=jpeg_std_error(&e);
    jpeg_create_decompress(&d);jpeg_mem_src(&d,jpeg,size);if(jpeg_read_header(&d,TRUE)!=JPEG_HEADER_OK)exit(11);
    d.out_color_space=JCS_RGB;jpeg_start_decompress(&d);
    if(d.output_width!=(unsigned)w||d.output_height!=(unsigned)h||d.output_components!=3)exit(12);
    while(d.output_scanline<d.output_height) { JSAMPROW row=rgb+(size_t)d.output_scanline*w*3; if(jpeg_read_scanlines(&d,&row,1)!=1)exit(13); }
    jpeg_finish_decompress(&d);jpeg_destroy_decompress(&d);return (size_t)w*h*3;
}
int main(int argc,char **argv) {
    int w,h,q,progressive,iterations,x,y,i;unsigned char *rgb,*jpeg=NULL;unsigned long size=0;size_t bytes=0;double start,elapsed;
#ifdef _WIN32
    if(!SetProcessAffinityMask(GetCurrentProcess(),1) || !SetPriorityClass(GetCurrentProcess(),HIGH_PRIORITY_CLASS)) {
        fprintf(stderr,"Could not configure benchmark scheduling: %lu\n",GetLastError());return 50;
    }
#endif
    if(getenv("JPEG_BENCH_MUTATE_CRT"))_putenv_s("JPEG_CRT_MUTATED", "1");
    if(argc<7)return 1;
    w=atoi(argv[2]);h=atoi(argv[3]);q=atoi(argv[4]);progressive=atoi(argv[5]);iterations=atoi(argv[6]);
    if(w<1||w>4096||h<1||h>4096||q<0||q>100||iterations<1||iterations>100000)return 2;
    rgb=(unsigned char*)malloc((size_t)w*h*3);if(!rgb)return 3;
    for(y=0;y<h;y++)for(x=0;x<w;x++) { size_t p=((size_t)y*w+x)*3; rgb[p]=(unsigned char)((x*255/w+(x*y%17))%256);rgb[p+1]=(unsigned char)((y*255/h+(x*y%11))%256);rgb[p+2]=(unsigned char)(((x+y)*127/(w+h)+(x*y%23))%256); }
    if(!strcmp(argv[1],"fixture")) { FILE *f;if(argc!=8)return 4;jpeg=encode(rgb,w,h,q,progressive,&size);f=fopen(argv[7],"wb");if(!f)return 5;if(fwrite(jpeg,1,size,f)!=size)return 6;fclose(f);free(jpeg);free(rgb);return 0; }
    if(!strcmp(argv[1],"decode")) { FILE *f;long n;if(argc!=8)return 4;f=fopen(argv[7],"rb");if(!f)return 5;fseek(f,0,SEEK_END);n=ftell(f);rewind(f);if(n<1)return 6;jpeg=(unsigned char*)malloc(n);if(!jpeg)return 3;if(fread(jpeg,1,n,f)!=(size_t)n)return 6;fclose(f);size=(unsigned long)n;decode(jpeg,size,rgb,w,h); }
    else if(!strcmp(argv[1],"encode")) { jpeg=encode(rgb,w,h,q,progressive,&size);free(jpeg);jpeg=NULL; }
    else return 7;
    start=now();
    for(i=0;i<iterations;i++) {
        if(!strcmp(argv[1],"encode")) { unsigned long n=0;unsigned char *data=encode(rgb,w,h,q,progressive,&n);bytes+=n;free(data); }
        else bytes+=decode(jpeg,size,rgb,w,h);
    }
    elapsed=now()-start;free(jpeg);free(rgb);
    printf("{\"operation\":\"%s\",\"version\":\"%s\",\"abi\":%d,\"iterations\":%d,\"seconds\":%.9f,\"bytes\":%.0f}\n",argv[1],STR(LIBJPEG_TURBO_VERSION),JPEG_LIB_VERSION,iterations,elapsed,(double)bytes);
    return 0;
}
