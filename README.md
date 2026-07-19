# Modern PHP SDK PGO runtime comparison

This orphan branch compares PHP-8.3 through master runtime artifacts built with
the modern PGO training changes against the previous successful branch builds.
Each PHP branch is tested in all four Windows architecture/thread-safety lanes.

The workflow runs paired, alternating benchmark samples on the same runner and
publishes the raw JSON results together with a Markdown summary.
