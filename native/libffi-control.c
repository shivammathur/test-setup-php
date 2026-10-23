#include <stdio.h>
#include <string.h>
#include <ffi.h>
static unsigned observed;
static void callback(ffi_cif *cif,void *ret,void **args,void *user) {
    observed=*(unsigned*)args[0];
    printf("callback: %u\n",observed);fflush(stdout);
    if (cif->rtype->type!=FFI_TYPE_VOID) *(ffi_arg*)ret=321;
}
int main(int argc,char **argv) {
    ffi_cif cif;ffi_type *args[]={&ffi_type_uint32};void *code;
    ffi_closure *cl=ffi_closure_alloc(sizeof(ffi_closure),&code);
    int is_cdecl=argc>1 && !strcmp(argv[1],"cdecl-void");
    int returns_int=argc>1 && !strcmp(argv[1],"stdcall-int");
    ffi_abi abi=is_cdecl?FFI_MS_CDECL:FFI_STDCALL;
    ffi_type *ret=returns_int?&ffi_type_uint32:&ffi_type_void;
    if(!cl || ffi_prep_cif(&cif,abi,1,ret,args)!=FFI_OK || ffi_prep_closure_loc(cl,&cif,callback,NULL,code)!=FFI_OK) return 2;
    printf("ABI=%u flags=%u bytes=%u trampoline=%p\n",cif.abi,cif.flags,cif.bytes,code);fflush(stdout);
    if (is_cdecl) ((void(__cdecl *)(unsigned))code)(123);
    else if (returns_int) printf("returned: %u\n",((unsigned(__stdcall *)(unsigned))code)(123));
    else ((void(__stdcall *)(unsigned))code)(123);
    printf("observed: %u\n",observed);fflush(stdout);
    ffi_closure_free(cl);
    return observed==123?0:3;
}
