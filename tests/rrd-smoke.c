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

int main(void) {
    const char *path = "librrd-smoke.rrd";
    const char *create_args[] = {
        "DS:value:GAUGE:5:U:U",
        "RRA:AVERAGE:0.5:1:16"
    };
    char update_one[64];
    char update_two[64];
    const char *updates[1];
    time_t base = time(NULL) - 10;
    time_t fetch_start;
    time_t fetch_end;
    unsigned long step = 0;
    unsigned long ds_count = 0;
    char **ds_names = NULL;
    rrd_value_t *data = NULL;
    rrd_info_t *info = NULL;
    size_t sample_count;
    size_t i;
    int found_value = 0;

    remove(path);
    printf("librrd version: %s\n", rrd_strversion());
    if (rrd_create_r(path, 1, base, 2, create_args) != 0) {
        return fail("rrd_create_r");
    }

    snprintf(update_one, sizeof(update_one), "%lld:42", (long long)(base + 1));
    updates[0] = update_one;
    if (rrd_update_r(path, NULL, 1, updates) != 0) {
        return fail("rrd_update_r(first)");
    }
    snprintf(update_two, sizeof(update_two), "%lld:43", (long long)(base + 2));
    updates[0] = update_two;
    if (rrd_update_r(path, NULL, 1, updates) != 0) {
        return fail("rrd_update_r(second)");
    }
    if (rrd_last_r(path) != base + 2) {
        fprintf(stderr, "rrd_last_r returned an unexpected timestamp\n");
        return 1;
    }

    info = rrd_info_r(path);
    if (info == NULL) {
        return fail("rrd_info_r");
    }
    rrd_info_free(info);

    fetch_start = base;
    fetch_end = base + 2;
    if (rrd_fetch_r(path, "AVERAGE", &fetch_start, &fetch_end, &step, &ds_count, &ds_names, &data) != 0) {
        return fail("rrd_fetch_r");
    }
    if (ds_count != 1 || ds_names == NULL || strcmp(ds_names[0], "value") != 0 || step != 1) {
        fprintf(stderr, "rrd_fetch_r returned unexpected metadata\n");
        return 1;
    }
    sample_count = (size_t)((fetch_end - fetch_start) / (time_t)step + 1) * ds_count;
    for (i = 0; i < sample_count; i++) {
        if (!isnan(data[i])) {
            found_value = 1;
        }
    }
    for (i = 0; i < ds_count; i++) {
        rrd_freemem(ds_names[i]);
    }
    rrd_freemem(ds_names);
    rrd_freemem(data);
    remove(path);
    if (!found_value) {
        fprintf(stderr, "rrd_fetch_r returned no finite samples\n");
        return 1;
    }
    puts("RRDtool create/update/info/fetch smoke test passed");
    return 0;
}
