# PHP SDK PGO tooling runtime comparison

This orphan branch compares the PHP runtime artifacts built before and after the
PHP SDK PGO tooling updates. Each PHP branch is tested in all four Windows
architecture/thread-safety lanes.

The workflow runs paired, alternating benchmark samples on the same runner and
publishes the raw JSON results together with a Markdown summary.

