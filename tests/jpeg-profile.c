#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>
#define STR_IMPL(x) #x
#define STR(x) STR_IMPL(x)
static LARGE_INTEGER frequency;
static double stamp(void){LARGE_INTEGER t;QueryPerformanceCounter(&t);return (double)t.QuadPart/frequency.QuadPart;}
int main(void){
    const char *keys[]={"JSIMD_FORCESSE2","JSIMD_FORCESSE","JSIMD_FORCEMMX","JSIMD_FORCE3DNOW","JSIMD_FORCENONE","JSIMD_NOHUFFENC"};
    unsigned char rgb[64*64*3];double totals[6]={0},t,envsafe,envplain,envwin;char value[2];size_t length;int i,k;volatile unsigned long sink=0;size_t environment_entries=0,environment_chars=0;LPCH environment=GetEnvironmentStringsA(),cursor;
    QueryPerformanceFrequency(&frequency);memset(rgb,100,sizeof(rgb));
    if(!environment)return 1;
    for(cursor=environment;*cursor;cursor+=strlen(cursor)+1){environment_entries++;environment_chars+=strlen(cursor)+1;}FreeEnvironmentStringsA(environment);
    t=stamp();for(i=0;i<10000;i++)for(k=0;k<6;k++)sink+=(unsigned long)getenv_s(&length,value,sizeof(value),keys[k]);envsafe=(stamp()-t)*1e6/10000;
    t=stamp();for(i=0;i<10000;i++)for(k=0;k<6;k++)sink+=getenv(keys[k])!=NULL;envplain=(stamp()-t)*1e6/10000;
    t=stamp();for(i=0;i<10000;i++)for(k=0;k<6;k++)sink+=GetEnvironmentVariableA(keys[k],value,sizeof(value));envwin=(stamp()-t)*1e6/10000;
    for(i=0;i<5000;i++){
        struct jpeg_compress_struct c;struct jpeg_error_mgr e;unsigned char *out=NULL;unsigned long size=0;
        t=stamp();c.err=jpeg_std_error(&e);jpeg_create_compress(&c);jpeg_mem_dest(&c,&out,&size);totals[0]+=stamp()-t;
        t=stamp();c.image_width=64;c.image_height=64;c.input_components=3;c.in_color_space=JCS_RGB;jpeg_set_defaults(&c);jpeg_set_quality(&c,75,TRUE);totals[1]+=stamp()-t;
        t=stamp();jpeg_start_compress(&c,TRUE);totals[2]+=stamp()-t;
        t=stamp();while(c.next_scanline<c.image_height){JSAMPROW row=rgb+c.next_scanline*64*3;if(jpeg_write_scanlines(&c,&row,1)!=1)return 2;}totals[3]+=stamp()-t;
        t=stamp();jpeg_finish_compress(&c);totals[4]+=stamp()-t;
        t=stamp();jpeg_destroy_compress(&c);free(out);totals[5]+=stamp()-t;
    }
    printf("{\"version\":\"%s\",\"bits\":%u,\"environment_entries\":%.0f,\"environment_chars\":%.0f,\"getenv_s_six_us\":%.6f,\"getenv_six_us\":%.6f,\"GetEnvironmentVariableA_six_us\":%.6f,\"phase_us\":{\"create\":%.6f,\"configure\":%.6f,\"start\":%.6f,\"scanlines\":%.6f,\"finish\":%.6f,\"destroy\":%.6f}}\n",STR(LIBJPEG_TURBO_VERSION),(unsigned)(sizeof(void*)*8),(double)environment_entries,(double)environment_chars,envsafe,envplain,envwin,totals[0]*200,totals[1]*200,totals[2]*200,totals[3]*200,totals[4]*200,totals[5]*200);
    return sink==0xffffffffUL ? 3:0;
}
