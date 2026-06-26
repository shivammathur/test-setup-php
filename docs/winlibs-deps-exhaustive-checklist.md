# Winlibs Dependency Exhaustive QA Checklist

This checklist is based on the PHP manual pages and the matching `php-src` stubs for PHP 8.2 through master. The suite treats function and method manifests as coverage gates: if PHP exposes a new userland symbol for one of these dependencies, the test fails until the checklist and assertions are updated.

## Shared Artifact Checks

- [x] Run every downloaded PHP artifact variant: x64 TS, x64 NTS, x86 TS, x86 NTS.
- [x] Verify CLI, Windows, architecture, thread safety, extension loading, `extension_dir`, PATH, and `ffi.enable`.
- [x] Capture `php -v`, `php -m`, and `php --ri` output for every loaded dependency extension.
- [x] Emit per-artifact JSON and JUnit reports.

## libcurl / ext/curl

Manuals:
- https://www.php.net/manual/en/book.curl.php
- https://www.php.net/manual/en/class.curlfile.php
- https://www.php.net/manual/en/class.curlstringfile.php

Checklist:
- [x] Account for every exposed `curl_*` function, with `curl_multi_get_handles()` and `curl_share_init_persistent()` treated as version-dependent optional symbols.
- [x] Account for `CurlHandle`, `CurlMultiHandle`, `CurlShareHandle`, optional `CurlSharePersistentHandle`, `CURLFile`, and `CURLStringFile`.
- [x] Verify libcurl version, SSL, zlib, HTTP/2, IPv6, brotli, zstd, NTLM, SMB, SMBS, protocol list, and version metadata.
- [x] Verify required constants for options, info values, multi, share, pause, and legacy protocol coverage.
- [x] Exercise HTTP GET, POST, redirects, headers, response metadata, header capture, cookies, gzip decoding, file downloads, file uploads, and string uploads.
- [x] Exercise `curl_copy_handle()`, `curl_reset()`, `curl_pause()`, `curl_upkeep()`, `curl_getinfo()`, `curl_escape()`, `curl_unescape()`, `curl_errno()`, `curl_error()`, and `curl_strerror()`.
- [x] Exercise `curl_multi_*` add/exec/select/info/getcontent/remove/errno/strerror/setopt and optional `curl_multi_get_handles()`.
- [x] Exercise `curl_share_*` cookie sharing, errno/strerror, share/unshare, and optional persistent share handles.
- [x] Exercise `file://` protocol and closed-port error behavior.

## libffi / ext/ffi

Manuals:
- https://www.php.net/manual/en/book.ffi.php
- https://www.php.net/manual/en/class.ffi.php

Checklist:
- [x] Account for every `FFI` method, `FFI\CData`, and every `FFI\CType` metadata method.
- [x] Verify key FFI constants and CType kind/ABI constants.
- [x] Exercise `cdef()`, `load()`, missing `scope()`, `new()`, unmanaged `free()`, `cast()`, `type()`, `typeof()`, `arrayType()`, `addr()`, `sizeof()`, `alignof()`, `memcpy()`, `memcmp()`, `memset()`, `string()`, and `isNull()`.
- [x] Exercise scalar, array, struct, enum, pointer, function pointer, and function parameter CType metadata when exposed.
- [x] Exercise Windows foreign calls through `kernel32.dll`.
- [x] Verify invalid declarations fail with `FFI\Exception`.

## GLib Runtime

Source surface:
- No PHP manual userland extension is exposed for GLib here; PHP reaches it indirectly through linked libraries. The suite validates the shipped GLib DLL directly through FFI.

Checklist:
- [x] Locate the shipped GLib DLL in every PHP artifact.
- [x] Exercise version compatibility and future-version mismatch reporting.
- [x] Exercise ASCII comparison, prefix/suffix helpers, UTF-8 length, UTF-8 validation success/failure, UTF-8 upper/lower conversion, string duplication/reversal, path basename, and allocated memory cleanup.

## libenchant2 / ext/enchant

Manual:
- https://www.php.net/manual/en/book.enchant.php

Checklist:
- [x] Account for every exposed `enchant_*` broker and dictionary function, including deprecated aliases that PHP still exposes.
- [x] Account for `EnchantBroker` and `EnchantDictionary`.
- [x] Verify Enchant constants and `LIBENCHANT_VERSION` when exposed.
- [x] Verify runtime module and dictionary paths.
- [x] Exercise broker init/free, provider description, dictionary listing, dictionary path getters/setters, ordering, error retrieval, dictionary existence, dictionary request, and deterministic PWL fallback.
- [x] Exercise dictionary describe, check, quick check with suggestions, suggest, add to session, add to personal, remove/remove from session when exposed, deprecated aliases, replacement storage, error retrieval, and free dict.

## ICU / icu4c / ext/intl

Manual:
- https://www.php.net/manual/en/book.intl.php

Checklist:
- [x] Account for every exposed `intl_*`, `intlcal_*`, `intlgregcal_*`, `collator_*`, `datefmt_*`, `numfmt_*`, `msgfmt_*`, `grapheme_*`, `locale_*`, `normalizer_*`, `resourcebundle_*`, `intltz_*`, `transliterator_*`, and `idn_*` function, with PHP-version-specific additions treated as optional symbols.
- [x] Account for every method on `Collator`, `NumberFormatter`, `IntlDateFormatter`, `IntlDatePatternGenerator`, `MessageFormatter`, `Normalizer`, `Locale`, `IntlCalendar`, `IntlGregorianCalendar`, `IntlTimeZone`, `ResourceBundle`, `Transliterator`, `Spoofchecker`, `IntlBreakIterator`, `IntlRuleBasedBreakIterator`, `IntlCodePointBreakIterator`, `IntlIterator`, `IntlPartsIterator`, `UConverter`, and `IntlChar`.
- [x] Verify intl loading, ICU version, ICU data version, Unicode version, IDNA constants, and `php --ri intl` output.
- [x] Exercise locale defaults, locale compose/parse/canonicalize/lookup/filter/HTTP negotiation, display names, scripts, regions, variants, keywords, likely-subtags, and right-to-left detection when exposed.
- [x] Exercise Unicode normalization, raw decomposition, grapheme length, split, extract, substring, forward/reverse/case-insensitive search, optional grapheme Levenshtein, and optional grapheme reverse.
- [x] Exercise `IntlChar` name/codepoint conversion, case mapping, folding, digit conversion, binary properties, direction, mirrored pairs, categories, block/script properties, numeric values, Unicode version, character predicates, name enumeration, and type enumeration.
- [x] Exercise IDNA U-label/A-label conversion.
- [x] Exercise collation comparison, strength, attributes, sorting, associative sorting, sort keys, locale/error metadata, and procedural aliases.
- [x] Exercise number, currency, spellout, parse, symbol, text attribute, pattern, locale/error metadata, and procedural aliases.
- [x] Exercise plural/select message formatting, static/procedural formatting and parsing, pattern mutation, locale/error metadata.
- [x] Exercise date/time formatting, parsing, localtime, parse-to-calendar, object formatting, calendar/timezone getters and setters, leniency, patterns, locale/error metadata, and pattern generator.
- [x] Exercise time zone creation, aliases, Windows/IANA mappings, canonical IDs, offsets, display names, DST rules, equivalent IDs, GMT/UTC/unknown zones, enumeration, conversion to/from `DateTimeZone`, and procedural aliases.
- [x] Exercise calendar creation, clear/set/get fields, date/time conversion, first day, minimal days, leniency, wall-time options, date math, field differences, limits, locale keywords, comparisons, Gregorian leap-year/change handling, and procedural aliases.
- [x] Exercise word, character, line, sentence, title, codepoint, and rule-based break iterators, positions, parts iterator, rule status, binary rules, and source iterator access.
- [x] Exercise resource bundles, counts, keys, nested values, locales, iterator access, errors, and procedural aliases.
- [x] Exercise transliterator creation from IDs and rules, inverse creation, list IDs, transliteration output, errors, and procedural aliases.
- [x] Exercise spoof checking for suspicious/confusable text, allowed locales/chars, checks, and restriction levels.
- [x] Exercise `UConverter` encoding conversion, transcode, source/destination metadata, converter lists, aliases, standards, substitution chars, callbacks, reason text, and errors.

## libjpeg-turbo / ext/gd JPEG Surface

Manual:
- https://www.php.net/manual/en/book.image.php

Checklist:
- [x] Verify GD JPEG support and JPEG constants.
- [x] Exercise `gd_info()`, `imagetypes()`, `imagejpeg()`, `imagecreatefromjpeg()`, `imagecreatefromstring()`, `getimagesize()`, `getimagesizefromstring()`, `image_type_to_mime_type()`, `image_type_to_extension()`, and optional `exif_imagetype()`.
- [x] Exercise JPEG output to file and output buffer.
- [x] Exercise quality 0, low quality, high quality, quality 100, and progressive JPEG output.
- [x] Verify dimensions, type detection, truecolor decode, string decode, resampling after decode, filtering after decode, and progressive SOF2 marker.
- [x] Verify invalid JPEG input fails with a warning.

## libtidy / ext/tidy

Manuals:
- https://www.php.net/manual/en/book.tidy.php
- https://www.php.net/manual/en/class.tidy.php
- https://www.php.net/manual/en/class.tidynode.php

Checklist:
- [x] Account for every exposed `tidy_*` procedural function.
- [x] Account for every `tidy` method and every `tidyNode` method.
- [x] Verify representative node and tag constants.
- [x] Verify libtidy release date and `php --ri tidy` libTidy version.
- [x] Exercise OO and procedural string parsing, file parsing, string repair, file repair, clean repair, diagnose, output retrieval, error buffer, config, status, HTML version, option values, option docs, XHTML/XML flags, and counters.
- [x] Exercise root/html/head/body accessors in OO and procedural forms.
- [x] Exercise node children, siblings, parent, previous/next sibling when exposed, HTML, text, comment, ASP, JSTE, and PHP predicates.
- [x] Verify direct `tidyNode` construction is not allowed.

## wineditline / ext/readline

Manual:
- https://www.php.net/manual/en/book.readline.php

Checklist:
- [x] If readline is absent, verify no `php_readline.dll` userland surface is present.
- [x] If readline is present, account for every exposed readline function, with history-list and callback helpers treated as build-dependent optional symbols.
- [x] Verify `READLINE_LIB`.
- [x] Exercise `readline_info()`, history clear/add/list/read/write, completion callback registration, callback handler install/read/remove, redisplay, and new-line hooks when exposed.
- [x] Exercise interactive `readline()` safely in a child PHP process with piped stdin.
