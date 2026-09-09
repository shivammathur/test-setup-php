{ print }
/^  PHP_DARWIN_PHASE=\$1$/ { print "  printf 'PHASE %s\\n' \"$1\" >&2" }
/^php_darwin_extract\(\) \($/ { print "printf 'EXTRACT begin\\n' >&2" }
/^php_darwin_read_metadata\(\) \($/ { print "printf 'METADATA begin\\n' >&2" }
/^php_darwin_existing_paths\(\) \($/ { print "printf 'PATHS begin\\n' >&2" }
/^filter_status=\$\?$/ { print "printf 'EXTRACT listed\\n' >&2" }
/^extract_status=\$\?$/ { print "printf 'EXTRACT unpacked\\n' >&2" }
/^done < "\$archive_members"$/ { print "printf 'EXTRACT permissions ready\\n' >&2" }
/^  cleanup_status=\$\?$/ { print "  printf 'PHASE cleanup\\n' >&2" }
