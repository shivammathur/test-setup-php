# Oniguruma 6.9.8 -> 6.9.10 Coverage

The workflow intentionally checks the user-visible PHP surface for changes
listed in `HISTORY` between 6.9.8 and 6.9.10.

| Upstream change | PHP-facing coverage |
| --- | --- |
| GCC 15 / C23 build fix in 6.9.10 | Not a PHP runtime behavior. The workflow validates the delivered Windows `php.exe` artifacts start, report the expected architecture/thread-safety, and run the suite on VS16/VS17-built artifacts. |
| Unicode 15.0/15.1 update in 6.9.9 | `\p{Kawi}` and `\p{Nag_Mundari}` property matching is recorded and required when the Oniguruma version supports it. |
| Unicode 16.0 update in 6.9.10 | `\p{Garay}` property matching is required for artifacts that declare Oniguruma 6.9.10. |
| Unicode property table regressions | Generated corpora test multiple positive and negative codepoints for `Kawi`, `Nag_Mundari`, and `Garay`, not just a single smoke sample. |
| POSIX punct definition changed to `\p{P} + \p{S}` | `[[:punct:]]` and `\p{PosixPunct}` are checked against ASCII punctuation and symbol punctuation. |
| POSIX punct corpus regressions | A generated corpus checks punctuation, symbol, connector punctuation, and non-punctuation samples against both `[[:punct:]]` and `\p{PosixPunct}`. |
| Negative POSIX bracket fix | `[[:^upper:]]` and `[[:^lower:]]` hit/miss behavior is checked. |
| POSIX bracket parser edge fixes | Literal colon bracket expressions and invalid POSIX names are checked for stable match/error behavior. |
| `.{0,99}` and `.*` short-input consistency | `\A.*\R`, `\A.{0,99}\R`, `\A.*\n`, `\A.{0,99}\n`, `\A.*\s`, and `\A.{0,99}\s` are checked against a one-byte newline. |
| `(?-i)` dynamic-library support fix | Inline case enabling/disabling is checked with `(?i)a(?-i)b`, `(?i:a)`, and `(?-i:a)`. |
| `(?n)`, `(?+n)`, `(?-n)` call-by-number fix | PHP mbstring does not expose those option forms; the suite asserts they remain compile errors and separately exercises supported numeric calls through `\g<...>`. |
| `FIND_LONGEST` follows all alternatives | `mb_regex_set_options('l')` is checked with alternatives that must return the longest `aaaa` match regardless of branch order. |
| Recursive call with whole/global options | `mb_regex_set_options('l')` is checked with `z|a\g<0>a` recursion, including the longer later match fixed in 6.9.10. |
| `ONIG_OPTION_MATCH_WHOLE_STRING` addition | PHP does not expose this Oniguruma option directly; the suite checks current `mb_ereg_match()` start-match behavior plus explicit `\z` whole-string anchoring. |
| BRE anchor at edge of subexpression | `mb_ereg_search()` with POSIX basic syntax checks `\(^ab\)` and `\(ab$\)`. |
| Retry limit zero means unlimited | `mbstring.regex_retry_limit=0` must allow a pathological match that fails at a finite retry limit. |
| `(*SKIP)` callout addition | PHP's regex syntax does not expose this callout; the suite asserts that it remains a compile error through `mb_ereg()`, so the PHP surface is stable. |
| `ONIG_SYN_ALLOW_CHAR_TYPE_FOLLOWED_BY_MINUS_IN_CC` | PHP's active syntax does not expose `[\w-%]`; the suite asserts that it remains a compile error. |
| `ONIG_SYNTAX_EMACS` shy-group fix | PHP mbstring does not use the Emacs syntax; the suite checks ordinary PHP noncapturing-group behavior stays stable. |
| Lookbehind/anchor empty-match fix | Positive and negative lookbehind around `X`, `$`, `\Z`, and `\z` are checked. |
| Literal escaped braces | `\{1\}`, anchored escaped braces, and grouped escaped braces are checked as literal matches. |
| Context-independent repeat operator edge cases | PHP-facing `^*` and `abc|?` compile-error behavior is checked for stability. |
| Whole-options / `(?I)` and `(?Ii)` handling | PHP's active syntax still rejects these whole-option forms; the suite records this stable PHP-facing behavior. |
| `\p{Word}` and `\w` ignorecase equivalence | `(?i)\p{Word}`, `(?i)\w`, `(?i)\P{Word}`, `(?i)\W`, and bracketed variants are checked with U+017F. |
| CMake/MSVC build-test and distclean `.pc` changes | Not PHP runtime behavior. Artifact extraction, extension loading, and full suite execution cover the produced Windows packages instead. |

The comparison job also enforces the expected feature-difference set for
6.9.8/6.9.9 baselines versus 6.9.10. Unexpected diffs, missing expected diffs,
missing matrix targets, and missing artifact/release report pairs fail CI.
