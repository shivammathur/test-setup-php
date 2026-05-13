/*
 * libffi 3.3 -> 3.5.2 Windows/PHP probe.
 *
 * This file is intentionally a normal C harness, not a PHPT.  It is compiled
 * twice by the workflow:
 *   - as ffi_probe.exe for direct libffi artifact validation;
 *   - as ffi_probe.dll so PHP FFI can load a DLL linked with the artifact.
 */

#define WIN32_LEAN_AND_MEAN

#include <ffi.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#ifdef _MSC_VER
# pragma warning(disable: 4054 4055 4152 4191)
# define EXPORT __declspec(dllexport)
# define STDCALL __stdcall
# define FASTCALL __fastcall
# define VECTORCALL __vectorcall
#else
# define EXPORT
# define STDCALL
# define FASTCALL
# define VECTORCALL
#endif

typedef struct probe_pair {
    int32_t a;
    double b;
} probe_pair;

typedef struct probe_small {
    uint8_t a;
    uint8_t b;
} probe_small;

typedef struct probe_big {
    int32_t a;
    double b;
    int64_t c;
} probe_big;

typedef int (__cdecl *probe_unary_cb)(int);

typedef struct report {
    char *buffer;
    size_t capacity;
    size_t length;
    unsigned int failures;
} report;

static int nearly_equal(double left, double right)
{
    double diff = fabs(left - right);
    return diff < 0.000001;
}

static void report_line(report *r, const char *group, const char *name, int pass, const char *detail)
{
    int written;

    if (!pass) {
        r->failures++;
    }

    if (!r->buffer || r->capacity == 0 || r->length >= r->capacity) {
        return;
    }

    written = snprintf(
        r->buffer + r->length,
        r->capacity - r->length,
        "RESULT|%s|%s|%s|%s\n",
        group,
        name,
        pass ? "PASS" : "FAIL",
        detail ? detail : ""
    );

    if (written <= 0) {
        return;
    }

    if ((size_t) written >= r->capacity - r->length) {
        r->length = r->capacity - 1;
        r->buffer[r->length] = '\0';
        return;
    }

    r->length += (size_t) written;
}

static void init_report(report *r, char *buffer, size_t capacity)
{
    r->buffer = buffer;
    r->capacity = capacity;
    r->length = 0;
    r->failures = 0;

    if (buffer && capacity > 0) {
        buffer[0] = '\0';
    }
}

EXPORT const char *probe_libffi_version(void)
{
    return ffi_get_version();
}

EXPORT unsigned long probe_libffi_version_number(void)
{
    return ffi_get_version_number();
}

EXPORT unsigned int probe_default_abi(void)
{
    return ffi_get_default_abi();
}

EXPORT size_t probe_closure_size(void)
{
    return ffi_get_closure_size();
}

EXPORT int probe_add(int left, int right)
{
    return left + right;
}

EXPORT double probe_mix(int32_t left, double middle, int64_t right)
{
    return (double) left + middle + (double) right;
}

EXPORT probe_pair probe_make_pair(int32_t left, double right)
{
    probe_pair value;
    value.a = left;
    value.b = right;
    return value;
}

EXPORT double probe_sum_pair(probe_pair value)
{
    return (double) value.a + value.b;
}

EXPORT int probe_fill_buffer(char *buffer, size_t capacity)
{
    const char *message = "ffi-buffer-ok";
    size_t needed = strlen(message) + 1;

    if (!buffer || capacity < needed) {
        return -1;
    }

    memcpy(buffer, message, needed);
    return (int) strlen(message);
}

EXPORT int probe_call_unary_callback(probe_unary_cb callback, int value)
{
    if (!callback) {
        return -1;
    }

    return callback(value) + 5;
}

static int target_add(int left, int right)
{
    return (left * 3) - right;
}

static double target_scalar_mix(int32_t a, uint64_t b, float c, double d)
{
    return (double) a + (double) b + (double) c + d;
}

static probe_pair target_make_pair(int32_t left, double right)
{
    probe_pair value;
    value.a = left;
    value.b = right;
    return value;
}

static double target_sum_pair(probe_pair value)
{
    return (double) value.a + value.b;
}

static probe_small target_make_small(uint8_t left, uint8_t right)
{
    probe_small value;
    value.a = left;
    value.b = right;
    return value;
}

static int target_sum_small(probe_small value)
{
    return (int) value.a + (int) value.b;
}

static probe_big target_make_big(int32_t a, double b, int64_t c)
{
    probe_big value;
    value.a = a;
    value.b = b;
    value.c = c;
    return value;
}

static double target_sum_big(probe_big value)
{
    return (double) value.a + value.b + (double) value.c;
}

static int target_sum_varargs(int count, ...)
{
    int i;
    int total = 0;
    va_list ap;

    va_start(ap, count);
    for (i = 0; i < count; i++) {
        total += va_arg(ap, int);
    }
    va_end(ap);

    return total;
}

static uint8_t target_identity_u8(uint8_t value)
{
    return (uint8_t) (value + 1u);
}

static double target_gp_sse_mix(
    int64_t a,
    int64_t b,
    int64_t c,
    int64_t d,
    int64_t e,
    int64_t f,
    double g,
    double h,
    int64_t i,
    double j
)
{
    return (double) (a + b + c + d + e + f + i) + g + h + j;
}

static int STDCALL target_stdcall(int left, int right)
{
    return left + right + 1000;
}

static int FASTCALL target_fastcall(int left, int right)
{
    return left + right + 2000;
}

static double VECTORCALL target_vectorcall(double left, double right, float third, int fourth)
{
    return left + right + (double) third + (double) fourth + 3000.0;
}

static void closure_handler(ffi_cif *cif, void *ret, void **args, void *user_data)
{
    int value;
    int base;

    (void) cif;

    value = *(int *) args[0];
    base = *(int *) user_data;
    *(int *) ret = value + base;
}

static ffi_type *type_sint32(void)
{
    return &ffi_type_sint32;
}

static ffi_type *type_double(void)
{
    return &ffi_type_double;
}

static void make_pair_type(ffi_type *type, ffi_type **elements)
{
    type->size = 0;
    type->alignment = 0;
    type->type = FFI_TYPE_STRUCT;
    type->elements = elements;
    elements[0] = &ffi_type_sint32;
    elements[1] = &ffi_type_double;
    elements[2] = NULL;
}

static void make_small_type(ffi_type *type, ffi_type **elements)
{
    type->size = 0;
    type->alignment = 0;
    type->type = FFI_TYPE_STRUCT;
    type->elements = elements;
    elements[0] = &ffi_type_uint8;
    elements[1] = &ffi_type_uint8;
    elements[2] = NULL;
}

static void make_big_type(ffi_type *type, ffi_type **elements)
{
    type->size = 0;
    type->alignment = 0;
    type->type = FFI_TYPE_STRUCT;
    type->elements = elements;
    elements[0] = &ffi_type_sint32;
    elements[1] = &ffi_type_double;
    elements[2] = &ffi_type_sint64;
    elements[3] = NULL;
}

static void test_metadata(report *r)
{
    const char *version = ffi_get_version();
    unsigned long version_number = ffi_get_version_number();
    unsigned int default_abi = ffi_get_default_abi();
    size_t closure_size = ffi_get_closure_size();

    report_line(r, "metadata", "version-string", strcmp(version, "3.5.2") == 0, version);
    report_line(r, "metadata", "version-number", version_number == 30502ul, "expected 30502");
    report_line(r, "metadata", "default-abi-range", default_abi > FFI_FIRST_ABI && default_abi < FFI_LAST_ABI, "default ABI is usable");
    report_line(r, "metadata", "closure-size", closure_size >= sizeof(ffi_closure), "ffi_get_closure_size covers ffi_closure");
    report_line(r, "metadata", "long-double-symbol", ffi_type_longdouble.size == ffi_type_double.size, "MSVC long double aliases double");
}

static void test_scalar_calls(report *r)
{
    ffi_cif cif;
    ffi_status status;
    ffi_type *args2[2];
    ffi_type *args4[4];
    void *values2[2];
    void *values4[4];
    int left = 9;
    int right = 4;
    int int_result = 0;
    int32_t a = -7;
    uint64_t b = 9007199254740991ULL;
    float c = 1.25f;
    double d = 2.5;
    double double_result = 0.0;
    double expected;

    args2[0] = type_sint32();
    args2[1] = type_sint32();
    values2[0] = &left;
    values2[1] = &right;

    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &ffi_type_sint32, args2);
    ffi_call(&cif, FFI_FN(target_add), &int_result, values2);
    report_line(r, "scalar", "cdecl-int32", status == FFI_OK && int_result == 23, "ffi_call cdecl int32");

    args4[0] = &ffi_type_sint32;
    args4[1] = &ffi_type_uint64;
    args4[2] = &ffi_type_float;
    args4[3] = &ffi_type_double;
    values4[0] = &a;
    values4[1] = &b;
    values4[2] = &c;
    values4[3] = &d;
    expected = target_scalar_mix(a, b, c, d);

    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 4, &ffi_type_double, args4);
    ffi_call(&cif, FFI_FN(target_scalar_mix), &double_result, values4);
    report_line(r, "scalar", "mixed-int-float-double", status == FFI_OK && nearly_equal(double_result, expected), "wide scalar argument mix");
}

static void test_structs(report *r)
{
    ffi_cif cif;
    ffi_status status;
    ffi_type pair_type;
    ffi_type *pair_elements[3];
    ffi_type small_type;
    ffi_type *small_elements[3];
    ffi_type big_type;
    ffi_type *big_elements[4];
    ffi_type *args3[3];
    ffi_type *args1[1];
    ffi_type *args2[2];
    void *values3[3];
    void *values1[1];
    void *values2[2];
    int32_t i = 17;
    double d = 9.5;
    int64_t l = 23;
    uint8_t b1 = 19;
    uint8_t b2 = 23;
    probe_pair pair_result;
    probe_small small_result;
    probe_big big_result;
    double double_result = 0.0;
    int int_result = 0;

    make_pair_type(&pair_type, pair_elements);
    make_small_type(&small_type, small_elements);
    make_big_type(&big_type, big_elements);

    args2[0] = &ffi_type_sint32;
    args2[1] = &ffi_type_double;
    values2[0] = &i;
    values2[1] = &d;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &pair_type, args2);
    ffi_call(&cif, FFI_FN(target_make_pair), &pair_result, values2);
    report_line(r, "structs", "return-int-double-struct", status == FFI_OK && pair_result.a == 17 && nearly_equal(pair_result.b, 9.5), "struct return");

    args1[0] = &pair_type;
    values1[0] = &pair_result;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_double, args1);
    ffi_call(&cif, FFI_FN(target_sum_pair), &double_result, values1);
    report_line(r, "structs", "pass-int-double-struct", status == FFI_OK && nearly_equal(double_result, 26.5), "struct by value");

    args2[0] = &ffi_type_uint8;
    args2[1] = &ffi_type_uint8;
    values2[0] = &b1;
    values2[1] = &b2;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &small_type, args2);
    ffi_call(&cif, FFI_FN(target_make_small), &small_result, values2);
    report_line(r, "structs", "return-two-byte-struct", status == FFI_OK && small_result.a == 19 && small_result.b == 23, "small struct return");

    args1[0] = &small_type;
    values1[0] = &small_result;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_sint32, args1);
    ffi_call(&cif, FFI_FN(target_sum_small), &int_result, values1);
    report_line(r, "structs", "pass-two-byte-struct", status == FFI_OK && int_result == 42, "small struct by value");

    args3[0] = &ffi_type_sint32;
    args3[1] = &ffi_type_double;
    args3[2] = &ffi_type_sint64;
    values3[0] = &i;
    values3[1] = &d;
    values3[2] = &l;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 3, &big_type, args3);
    ffi_call(&cif, FFI_FN(target_make_big), &big_result, values3);
    report_line(r, "structs", "return-big-struct", status == FFI_OK && big_result.a == 17 && nearly_equal(big_result.b, 9.5) && big_result.c == 23, "large struct return");

    args1[0] = &big_type;
    values1[0] = &big_result;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_double, args1);
    ffi_call(&cif, FFI_FN(target_sum_big), &double_result, values1);
    report_line(r, "structs", "pass-big-struct", status == FFI_OK && nearly_equal(double_result, 49.5), "large struct by value");
}

static void test_varargs(report *r)
{
    ffi_cif cif;
    ffi_type *args[4];
    void *values[4];
    int count = 3;
    int a = 10;
    int b = 20;
    int c = 30;
    int result = 0;
    ffi_status status;

    args[0] = &ffi_type_sint32;
    args[1] = &ffi_type_sint32;
    args[2] = &ffi_type_sint32;
    args[3] = &ffi_type_sint32;
    values[0] = &count;
    values[1] = &a;
    values[2] = &b;
    values[3] = &c;

    status = ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, 1, 4, &ffi_type_sint32, args);
    ffi_call(&cif, FFI_FN(target_sum_varargs), &result, values);
    report_line(r, "varargs", "prep-cif-var-int-sum", status == FFI_OK && result == 60, "ffi_prep_cif_var");
}

static void test_closures(report *r)
{
    ffi_cif cif;
    ffi_type *args[1];
    ffi_closure *closure;
    void *code = NULL;
    int base = 70;
    int result;
    ffi_status status;
    typedef int (*closure_fn)(int);

    args[0] = &ffi_type_sint32;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_sint32, args);
    closure = (ffi_closure *) ffi_closure_alloc(sizeof(ffi_closure), &code);

    if (status != FFI_OK || !closure || !code) {
        report_line(r, "closures", "alloc-and-prep", 0, "ffi_closure_alloc failed");
        if (closure) {
            ffi_closure_free(closure);
        }
        return;
    }

    status = ffi_prep_closure_loc(closure, &cif, closure_handler, &base, code);
    if (status == FFI_OK) {
        result = ((closure_fn) code)(5);
        report_line(r, "closures", "call-prepared-closure", result == 75, "ffi_prep_closure_loc executable callback");
    } else {
        report_line(r, "closures", "call-prepared-closure", 0, "ffi_prep_closure_loc failed");
    }

    ffi_closure_free(closure);
}

static void test_calling_conventions(report *r)
{
    ffi_cif cif;
    ffi_type *args2[2];
    ffi_type *args4[4];
    void *values2[2];
    void *values4[4];
    int left = 11;
    int right = 31;
    int int_result = 0;
    double d1 = 1.5;
    double d2 = 2.5;
    float f = 3.5f;
    int i = 4;
    double double_result = 0.0;
    ffi_status status;

    args2[0] = &ffi_type_sint32;
    args2[1] = &ffi_type_sint32;
    values2[0] = &left;
    values2[1] = &right;

#if defined(X86_WIN32) && defined(FFI_STDCALL)
    status = ffi_prep_cif(&cif, FFI_STDCALL, 2, &ffi_type_sint32, args2);
    ffi_call(&cif, FFI_FN(target_stdcall), &int_result, values2);
    report_line(r, "calling-conventions", "x86-stdcall", status == FFI_OK && int_result == 1042, "FFI_STDCALL");
#else
    report_line(r, "calling-conventions", "x86-stdcall", 1, "not applicable on this architecture");
#endif

#if defined(X86_WIN32) && defined(FFI_FASTCALL)
    int_result = 0;
    status = ffi_prep_cif(&cif, FFI_FASTCALL, 2, &ffi_type_sint32, args2);
    ffi_call(&cif, FFI_FN(target_fastcall), &int_result, values2);
    report_line(r, "calling-conventions", "x86-fastcall", status == FFI_OK && int_result == 2042, "FFI_FASTCALL");
#else
    report_line(r, "calling-conventions", "x86-fastcall", 1, "not applicable on this architecture");
#endif

#if defined(X86_WIN32) && defined(FFI_MS_CDECL)
    int_result = 0;
    status = ffi_prep_cif(&cif, FFI_MS_CDECL, 2, &ffi_type_sint32, args2);
    ffi_call(&cif, FFI_FN(target_add), &int_result, values2);
    report_line(r, "calling-conventions", "x86-ms-cdecl", status == FFI_OK && int_result == 2, "FFI_MS_CDECL");
#else
    report_line(r, "calling-conventions", "x86-ms-cdecl", 1, "not applicable on this architecture");
#endif

#if defined(X86_WIN64) && defined(FFI_WIN64)
    int_result = 0;
    status = ffi_prep_cif(&cif, FFI_WIN64, 2, &ffi_type_sint32, args2);
    ffi_call(&cif, FFI_FN(target_add), &int_result, values2);
    report_line(r, "calling-conventions", "x64-win64", status == FFI_OK && int_result == 2, "FFI_WIN64");
#else
    report_line(r, "calling-conventions", "x64-win64", 1, "not applicable on this architecture");
#endif

#if defined(FFI_VECTORCALL_PARTIAL)
    args4[0] = &ffi_type_double;
    args4[1] = &ffi_type_double;
    args4[2] = &ffi_type_float;
    args4[3] = &ffi_type_sint32;
    values4[0] = &d1;
    values4[1] = &d2;
    values4[2] = &f;
    values4[3] = &i;
    status = ffi_prep_cif(&cif, FFI_VECTORCALL_PARTIAL, 4, &ffi_type_double, args4);
    ffi_call(&cif, FFI_FN(target_vectorcall), &double_result, values4);
    report_line(r, "calling-conventions", "vectorcall-partial", status == FFI_OK && nearly_equal(double_result, 3011.5), "FFI_VECTORCALL_PARTIAL");
#else
    report_line(r, "calling-conventions", "vectorcall-partial", 0, "FFI_VECTORCALL_PARTIAL missing");
#endif
}

static void test_overread_guard(report *r)
{
    SYSTEM_INFO info;
    char *pages;
    char *guard;
    DWORD old_protect = 0;
    uint8_t *slot;
    uint8_t result = 0;
    ffi_cif cif;
    ffi_type *args[1];
    void *values[1];
    ffi_status status;

    GetSystemInfo(&info);
    pages = (char *) VirtualAlloc(NULL, info.dwPageSize * 2, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!pages) {
        report_line(r, "memory-safety", "guarded-u8-argument", 0, "VirtualAlloc failed");
        return;
    }

    guard = pages + info.dwPageSize;
    if (!VirtualProtect(guard, info.dwPageSize, PAGE_NOACCESS, &old_protect)) {
        VirtualFree(pages, 0, MEM_RELEASE);
        report_line(r, "memory-safety", "guarded-u8-argument", 0, "VirtualProtect failed");
        return;
    }

    slot = (uint8_t *) (pages + info.dwPageSize - 1);
    *slot = 41;

    args[0] = &ffi_type_uint8;
    values[0] = slot;
    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_uint8, args);
    ffi_call(&cif, FFI_FN(target_identity_u8), &result, values);

    VirtualFree(pages, 0, MEM_RELEASE);
    report_line(r, "memory-safety", "guarded-u8-argument", status == FFI_OK && result == 42, "catches x86-64 small-arg overread regression");
}

static void test_register_mix(report *r)
{
    ffi_cif cif;
    ffi_type *args[10];
    void *values[10];
    int64_t i1 = 1;
    int64_t i2 = 2;
    int64_t i3 = 3;
    int64_t i4 = 4;
    int64_t i5 = 5;
    int64_t i6 = 6;
    int64_t i7 = 7;
    double d1 = 8.25;
    double d2 = 9.25;
    double d3 = 10.25;
    double result = 0.0;
    double expected = 55.75;
    ffi_status status;
    int index;

    for (index = 0; index < 10; index++) {
        args[index] = &ffi_type_sint64;
    }

    args[6] = &ffi_type_double;
    args[7] = &ffi_type_double;
    args[9] = &ffi_type_double;

    values[0] = &i1;
    values[1] = &i2;
    values[2] = &i3;
    values[3] = &i4;
    values[4] = &i5;
    values[5] = &i6;
    values[6] = &d1;
    values[7] = &d2;
    values[8] = &i7;
    values[9] = &d3;

    status = ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 10, &ffi_type_double, args);
    ffi_call(&cif, FFI_FN(target_gp_sse_mix), &result, values);
    report_line(r, "registers", "gp-sse-mixed-arguments", status == FFI_OK && nearly_equal(result, expected), "x86-64 GP/SSE register mix");
}

EXPORT int probe_run_all(char *buffer, size_t capacity)
{
    report r;

    init_report(&r, buffer, capacity);
    test_metadata(&r);
    test_scalar_calls(&r);
    test_structs(&r);
    test_varargs(&r);
    test_closures(&r);
    test_calling_conventions(&r);
    test_overread_guard(&r);
    test_register_mix(&r);

    return (int) r.failures;
}

#ifdef PROBE_EXE
int main(void)
{
    char *buffer = (char *) calloc(1, 1024 * 1024);
    int failures;

    if (!buffer) {
        fputs("RESULT|harness|allocation|FAIL|calloc failed\n", stderr);
        return 2;
    }

    failures = probe_run_all(buffer, 1024 * 1024);
    fputs(buffer, stdout);
    free(buffer);

    return failures == 0 ? 0 : 1;
}
#endif
