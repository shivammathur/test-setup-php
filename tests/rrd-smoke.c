#define _CRT_SECURE_NO_WARNINGS
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <rrd.h>

static int fail(const char *operation) {
    fprintf(stderr, "%s failed: %s\n", operation, rrd_test_error() ? rrd_get_error() : "unknown error");
    rrd_clear_error();
    return 1;
}

static int verify_samples(const char *path, time_t base) {
    time_t fetch_start = base;
    time_t fetch_end = base + 2;
    unsigned long step = 0;
    unsigned long ds_count = 0;
    char **ds_names = NULL;
    rrd_value_t *data = NULL;
    size_t sample_count;
    size_t i;
    int valid;
    if (rrd_last_r(path) != base + 2) {
        fprintf(stderr, "rrd_last_r returned an unexpected timestamp\n");
        return 1;
    }

    if (rrd_fetch_r(path, "AVERAGE", &fetch_start, &fetch_end, &step, &ds_count, &ds_names, &data) != 0) {
        return fail("rrd_fetch_r");
    }
    if (ds_count != 1 || ds_names == NULL || strcmp(ds_names[0], "value") != 0 || step != 1) {
        fprintf(stderr, "rrd_fetch_r returned unexpected metadata\n");
        return 1;
    }
    /* rrd_fetch_r initializes (end-start)/step rows, not its padding row. */
    sample_count = (size_t)((fetch_end - fetch_start) / (time_t)step) * ds_count;
    valid = fetch_start == base && fetch_end == base + 3 && sample_count == 3 &&
            data != NULL && isfinite(data[0]) && isfinite(data[1]) &&
            fabs(data[0] - 42.0) < 1e-10 && fabs(data[1] - 43.0) < 1e-10 &&
            isnan(data[2]);
    for (i = 0; i < ds_count; i++) {
        rrd_freemem(ds_names[i]);
    }
    rrd_freemem(ds_names);
    rrd_freemem(data);
    if (!valid) {
        fprintf(stderr, "rrd_fetch_r did not return the expected timestamped 42/43/NaN samples\n");
        return 1;
    }
    return 0;
}

static int reject_xml(const char *content) {
    const char *args[] = {"restore", "invalid.xml", "invalid.rrd"};
    FILE *file;
    int result;
    remove("invalid.xml");
    remove("invalid.rrd");
    file = fopen("invalid.xml", "wb");
    if (file == NULL) return 1;
    if (fputs(content, file) == EOF) {
        fclose(file);
        return 1;
    }
    if (fclose(file) != 0) return 1;
    rrd_clear_error();
    result = rrd_restore(3, args);
    if (result == 0 || !rrd_test_error()) {
        fprintf(stderr, "rrd_restore did not reject malformed XML\n");
        return 1;
    }
    printf("Malformed XML rejected: %s\n", rrd_get_error());
    rrd_clear_error();
    file = fopen("invalid.rrd", "rb");
    if (file != NULL) {
        fclose(file);
        fprintf(stderr, "Failed restore unexpectedly created a database\n");
        return 1;
    }
    remove("invalid.xml");
    return 0;
}

int main(void) {
    const char *path = "librrd-smoke.rrd";
    const char *create_args[] = {"DS:value:GAUGE:5:U:U", "RRA:AVERAGE:0.5:1:16"};
    const char *restore_args[] = {"restore", "librrd-smoke.xml", "restored.rrd"};
    char xml_path[] = "librrd-smoke.xml";
    char update[64];
    const char *updates[] = {update};
    time_t base = time(NULL) - 10;
    rrd_info_t *info;
    remove(path);
    remove(xml_path);
    remove("restored.rrd");
    printf("librrd version: %s\n", rrd_strversion());
    if (rrd_create_r(path, 1, base, 2, create_args) != 0) return fail("rrd_create_r");
    snprintf(update, sizeof(update), "%lld:42", (long long)(base + 1));
    if (rrd_update_r(path, NULL, 1, updates) != 0) return fail("rrd_update_r(first)");
    snprintf(update, sizeof(update), "%lld:43", (long long)(base + 2));
    if (rrd_update_r(path, NULL, 1, updates) != 0) return fail("rrd_update_r(second)");
    info = rrd_info_r(path);
    if (info == NULL) return fail("rrd_info_r");
    rrd_info_free(info);
    if (verify_samples(path, base)) return 1;
    puts("PASS create/update/info/fetch: exact samples verified");
    if (rrd_dump_r(path, xml_path) != 0) return fail("rrd_dump_r");
    if (rrd_restore(3, restore_args) != 0) return fail("rrd_restore(valid XML)");
    if (verify_samples("restored.rrd", base)) return 1;
    puts("PASS XML dump/restore: timestamp and samples preserved");
    if (reject_xml("<rrd><version>0003</wrong></rrd>")) return 1;
    if (reject_xml("<rrd><version>0003</version><step>1")) return 1;
    puts("PASS malformed XML: mismatched and truncated input rejected");
    remove(path);
    remove(xml_path);
    remove("restored.rrd");
    puts("RRDtool native XML consumer QA passed");
    return 0;
}
