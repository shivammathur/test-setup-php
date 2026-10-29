#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define JPEG_INTERNALS
#include "jinclude.h"
#include "jpeglib.h"
#include "jsimdconst.h"

static unsigned int huffman;
static unsigned int mask(void)
{
    struct jpeg_compress_struct c;struct jpeg_error_mgr e;
    unsigned char *data=NULL;unsigned long size=0;unsigned int result;
    c.err=jpeg_std_error(&e);jpeg_create_compress(&c);jpeg_mem_dest(&c,&data,&size);
    c.image_width=64;c.image_height=64;c.input_components=3;c.in_color_space=JCS_RGB;
    jpeg_set_defaults(&c);jpeg_start_compress(&c,TRUE);
    result=c.master->simd_support;huffman=c.master->simd_huffman;
    jpeg_abort_compress(&c);jpeg_destroy_compress(&c);free(data);return result;
}

static void set_crt(const char *name,const char *value)
{
    if(_putenv_s(name,value))exit(20);
}

static void set_os(const char *name,const char *value)
{
    if(!SetEnvironmentVariableA(name,value))exit(21);
}

int main(int argc,char **argv)
{
    unsigned int hardware,crt_only,os_only;char env[2]={0};size_t needed=0;int patched,i;
    char long_value[4096];const char *invalid[]={"0","11","true"," 1","1 ",""};
    if(argc!=2)return 1;patched=!strcmp(argv[1],"patched");
    set_crt("JSIMD_FORCESSE2","");set_crt("JSIMD_FORCESSE","");set_crt("JSIMD_FORCEMMX","");
    set_crt("JSIMD_FORCE3DNOW","");set_crt("JSIMD_NOHUFFENC","");
    /* The first object disables SIMD; subsequent objects must recover hardware capabilities. */
    set_crt("JSIMD_FORCENONE","1");if(mask()!=0)return 2;
    set_crt("JSIMD_FORCENONE","");hardware=mask();if(!hardware||hardware==JSIMD_UNDEFINED)return 3;
    for(i=0;i<6;i++){set_crt("JSIMD_FORCENONE",invalid[i]);if(mask()!=hardware)return 4;}
    memset(long_value,'1',sizeof(long_value)-1);long_value[sizeof(long_value)-1]=0;
    set_crt("JSIMD_FORCENONE",long_value);if(mask()!=hardware)return 5;
    set_crt("JSIMD_FORCENONE","");
    set_crt("jsimd_forcenone","1");if(mask()!=0)return 6;set_crt("jsimd_forcenone","");
    if(_wputenv_s(L"JSIMD_FORCENONE",L"1")||mask()!=0)return 7;
    if(_wputenv_s(L"JSIMD_FORCENONE",L"")||mask()!=hardware)return 8;
    set_crt("JSIMD_NOHUFFENC","1");mask();if(huffman!=0)return 9;
    set_crt("JSIMD_NOHUFFENC","");mask();if(huffman!=1)return 10;
    /* Supported APIs can leave the CRT and Windows environment with different values. */
    set_crt("JSIMD_FORCENONE","1");set_os("JSIMD_FORCENONE",NULL);
    if(getenv_s(&needed,env,sizeof(env),"JSIMD_FORCENONE")||strcmp(env,"1"))return 11;
    crt_only=mask();if(crt_only!=(patched?hardware:0))return 12;
    set_crt("JSIMD_FORCENONE","");set_os("JSIMD_FORCENONE","1");
    os_only=mask();if(os_only!=(patched?0:hardware))return 13;
    set_os("JSIMD_FORCENONE",NULL);
    printf("{\"variant\":\"%s\",\"normal_controls_passed\":true,\"cold_first_forcenone_passed\":true,\"invalid_and_long_values_passed\":true,\"hardware_mask\":%u,\"crt_only_override_mask\":%u,\"os_only_override_mask\":%u,\"environment_source_changes_behavior\":true}\n",argv[1],hardware,crt_only,os_only);
    return 0;
}
