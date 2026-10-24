#include <gio/gio.h>
#include <string.h>

int main(void) {
    guint8 input[65536], compressed[131072], output[131072];
    GError *error = NULL;
    guint format, level, i;
    g_assert_cmpuint(glib_major_version, ==, 2);
    g_assert_cmpuint(glib_minor_version, ==, 90);
    g_assert_cmpuint(glib_micro_version, ==, 1);
    for (i = 0; i < sizeof input; ++i) input[i] = (guint8)(i % 251);
    for (format = 0; format <= 2; ++format) {
        for (level = 0; level <= 9; ++level) {
            gsize read = 0, written = 0, decoded = 0, consumed = 0;
            GZlibCompressor *compressor = g_zlib_compressor_new((GZlibCompressorFormat)format, level);
            GZlibDecompressor *decompressor = g_zlib_decompressor_new((GZlibCompressorFormat)format);
            GConverterResult result = g_converter_convert(G_CONVERTER(compressor), input, sizeof input,
                compressed, sizeof compressed, G_CONVERTER_INPUT_AT_END, &read, &written, &error);
            g_assert_no_error(error);
            g_assert_cmpint(result, ==, G_CONVERTER_FINISHED);
            g_assert_cmpuint(read, ==, sizeof input);
            result = g_converter_convert(G_CONVERTER(decompressor), compressed, written,
                output, sizeof output, G_CONVERTER_INPUT_AT_END, &consumed, &decoded, &error);
            g_assert_no_error(error);
            g_assert_cmpint(result, ==, G_CONVERTER_FINISHED);
            g_assert_cmpuint(consumed, ==, written);
            g_assert_cmpuint(decoded, ==, sizeof input);
            g_assert_cmpmem(input, sizeof input, output, decoded);
            g_object_unref(decompressor);
            g_object_unref(compressor);
        }
    }
    {
        gchar *normalized = g_utf8_normalize("e\314\201", -1, G_NORMALIZE_NFC);
        g_assert_cmpstr(normalized, ==, "\303\251");
        g_free(normalized);
        g_assert_null(g_utf8_normalize("\377", 1, G_NORMALIZE_NFC));
    }
    {
        GVariant *value = g_variant_ref_sink(g_variant_new("(si)", "Windows GLib QA", 42));
        GBytes *bytes = g_variant_get_data_as_bytes(value);
        GVariant *copy = g_variant_ref_sink(g_variant_new_from_bytes(G_VARIANT_TYPE("(si)"), bytes, FALSE));
        g_assert_true(g_variant_equal(value, copy));
        g_variant_unref(copy);
        g_bytes_unref(bytes);
        g_variant_unref(value);
    }
    g_print("GLib 2.90.1: 30 GIO zlib round trips, Unicode normalization and GVariant serialization passed\n");
    return 0;
}
