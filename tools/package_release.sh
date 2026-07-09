#!/usr/bin/env bash
# Builds squirrelc and bundles it with the pixi-env shared libraries it
# links against (libKGENCompilerRTShared.so and friends -- Mojo builds
# aren't statically linked, so a bare executable only works on a machine
# that happens to have the exact same pixi env at the exact same path it
# was built with). `-Xlinker -rpath -Xlinker '$ORIGIN/lib'` makes the
# binary look for those libraries next to itself first, so the bundle
# works unpacked anywhere -- verified by running it from a location with
# no access to this repo or its pixi env at all. System libraries
# (libc/libm/libdl/the dynamic linker itself) are left alone; only the
# ones actually resolving inside .pixi/envs/default/lib get copied in.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rm -rf dist
mkdir -p dist/lib

mojo build -I src -o dist/squirrelc src/main.mojo \
    -Xlinker -rpath -Xlinker '$ORIGIN/lib'

pixi_lib_dir="$(pwd)/.pixi/envs/default/lib"
ldd dist/squirrelc | awk '{print $3}' | grep "^${pixi_lib_dir}/" | while read -r lib; do
    cp "$lib" dist/lib/
done

echo "Packaged dist/squirrelc with $(ls dist/lib | wc -l) bundled librar(y/ies):"
ls dist/lib
