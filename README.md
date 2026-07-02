# GD Windows Artifact Checks

This orphan branch tests GD support from a php-windows-builder artifact bundle.

The default workflow input uses php-windows-builder run `28612131370`, which was
built from the GD branch with libjxl, libheif, libtiff, and libultrahdr artifacts
from shivammathur/winlib-builder.

The PHP test loads `ext/php_gd.dll`, exercises the public GD/AVIF userland API,
and checks the built `php_gd.dll` payload for static-library markers for:

- libheif
- libjxl
- libtiff
- libultrahdr

The current PHP GD userland API does not expose separate `imagejxl`,
`imageheif`, `imagetiff`, or `imageuhdr` functions, so those libraries are
validated as linked static payload in the GD extension artifact.
