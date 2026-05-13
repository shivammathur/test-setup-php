/*
 * Plain C target for testing PHP's rebuilt FFI extension.
 *
 * This DLL intentionally does not link against libffi.  PHP's ext/ffi is the
 * libffi consumer under test; this target only provides C ABI shapes for PHP
 * FFI to call.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifdef _MSC_VER
# define EXPORT __declspec(dllexport)
# define CDECL __cdecl
#else
# define EXPORT
# define CDECL
#endif

typedef struct plain_pair {
    int32_t a;
    double b;
} plain_pair;

typedef struct plain_small {
    uint8_t a;
    uint8_t b;
} plain_small;

typedef struct plain_big {
    int32_t a;
    int32_t b;
    int32_t c;
    int32_t d;
    int32_t e;
    int32_t f;
    int32_t g;
    int32_t h;
} plain_big;

typedef struct plain_single {
    int32_t value;
} plain_single;

typedef struct plain_nested_inner {
    int32_t value;
} plain_nested_inner;

typedef struct plain_nested {
    plain_nested_inner inner;
    double weight;
} plain_nested;

typedef int (CDECL *plain_unary_cb)(int);

EXPORT const char *CDECL plain_marker(void)
{
    return "php-ffi-plain-target";
}

EXPORT int32_t CDECL plain_add(int32_t left, int32_t right)
{
    return left + right;
}

EXPORT double CDECL plain_mix(int32_t left, double middle, int64_t right)
{
    return (double) left + middle + (double) right;
}

EXPORT uint8_t CDECL plain_return_u8(uint8_t value)
{
    return (uint8_t) (value + 1u);
}

EXPORT int16_t CDECL plain_return_s16(int16_t value)
{
    return (int16_t) (value - 2);
}

EXPORT int64_t CDECL plain_return_s64(int64_t value)
{
    return value + 42;
}

EXPORT plain_pair CDECL plain_make_pair(int32_t left, double right)
{
    plain_pair value;
    value.a = left;
    value.b = right;
    return value;
}

EXPORT double CDECL plain_sum_pair(plain_pair value)
{
    return (double) value.a + value.b;
}

EXPORT plain_small CDECL plain_make_small(uint8_t left, uint8_t right)
{
    plain_small value;
    value.a = left;
    value.b = right;
    return value;
}

EXPORT int32_t CDECL plain_sum_small(plain_small value)
{
    return (int32_t) value.a + (int32_t) value.b;
}

EXPORT plain_big CDECL plain_make_big(int32_t seed)
{
    plain_big value;
    value.a = seed;
    value.b = seed + 1;
    value.c = seed + 2;
    value.d = seed + 3;
    value.e = seed + 4;
    value.f = seed + 5;
    value.g = seed + 6;
    value.h = seed + 7;
    return value;
}

EXPORT int32_t CDECL plain_sum_big(plain_big value)
{
    return value.a + value.b + value.c + value.d + value.e + value.f + value.g + value.h;
}

EXPORT plain_single CDECL plain_make_single(int32_t value)
{
    plain_single result;
    result.value = value;
    return result;
}

EXPORT int32_t CDECL plain_unbox_single(plain_single value)
{
    return value.value;
}

EXPORT plain_nested CDECL plain_make_nested(int32_t value, double weight)
{
    plain_nested result;
    result.inner.value = value;
    result.weight = weight;
    return result;
}

EXPORT double CDECL plain_sum_nested(plain_nested value)
{
    return (double) value.inner.value + value.weight;
}

EXPORT int CDECL plain_fill_buffer(char *buffer, size_t capacity)
{
    const char *message = "php-ffi-buffer-ok";
    size_t needed = strlen(message) + 1;

    if (!buffer || capacity < needed) {
        return -1;
    }

    memcpy(buffer, message, needed);
    return (int) strlen(message);
}

EXPORT int CDECL plain_call_unary_callback(plain_unary_cb callback, int value)
{
    if (!callback) {
        return -1;
    }

    return callback(value) + 5;
}

EXPORT int CDECL plain_sum_varargs_int(int count, ...)
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

EXPORT double CDECL plain_sum_varargs_double(int count, ...)
{
    int i;
    double total = 0.0;
    va_list ap;

    va_start(ap, count);
    for (i = 0; i < count; i++) {
        total += va_arg(ap, double);
    }
    va_end(ap);

    return total;
}

EXPORT double CDECL plain_gp_sse_mix(int32_t a, uint64_t b, float c, double d)
{
    return (double) a + (double) b + (double) c + d;
}
