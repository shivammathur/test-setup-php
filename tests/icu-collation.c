/* ICU-20715 regression input from unicode-org/icu commit
 * 4833cc89b2fae2e8863b46bf1dc785964847e882, CollationTest::TestBuilderContextsOverflow.
 * ICU license: https://github.com/unicode-org/icu/blob/release-71-1/LICENSE */
#include <unicode/ucol.h>
#include <unicode/uversion.h>
#include <stdio.h>
int main(void) {
    UChar rules[] = {
        '&', 0x10, 0x2ff, 0x503c, 0x4617,
        '=', 0x80, 0x4f7f, 0xff, 0x3c3d, 0x1c4f, 0x3c3c,
        '<', 0, 0, 0, 0, '|', 0, 0, 0, 0, 0, 0xf400, 0x30ff, 0, 0, 0x4f7f, 0xff,
        '=', 0, '|', 0, 0, 0, 0, 0, 0, 0x1f00, 0xe30,
        0x3035, 0, 0, 0xd200, 0, 0x7f00, 0xff4f, 0x3d00, 0, 0x7c00,
        0, 0, 0, 0, 0, 0, 0, 0x301f, 0x350e, 0x30,
        0, 0, 0xd2, 0x7c00, 0, 0, 0, 0, 0, 0,
        0, 0x301f, 0x350e, 0x30, 0, 0, 0x52d2, 0x2f3c, 0x5552, 0x493c,
        0x1f10, 0x1f50, 0x300, 0, 0, 0xf400, 0x30ff, 0, 0, 0x4f7f,
        0xff,
        '=', 0, '|', 0, 0, 0, 0, 0x5000, 0x4617,
        '=', 0x80, 0x4f7f, 0, 0, 0xd200, 0
    };
    UErrorCode status = U_ZERO_ERROR;
    UParseError parse;
    UVersionInfo version;
    UCollator *collator;
    u_getVersion(version);
    if (version[0] != 71 || version[1] != 1) {
        fprintf(stderr, "Unexpected ICU runtime %d.%d\n", version[0], version[1]);
        return 2;
    }
    collator = ucol_openRules(rules, sizeof(rules)/sizeof(rules[0]), UCOL_DEFAULT, UCOL_DEFAULT_STRENGTH, &parse, &status);
    if (U_FAILURE(status) || collator == NULL) {
        fprintf(stderr, "ICU-20715: %s\n", u_errorName(status));
        return 1;
    }
    ucol_close(collator);
    puts("PASS: ICU-20715 context overflow regression with ICU 71.1 artifact DLLs");
    return 0;
}
