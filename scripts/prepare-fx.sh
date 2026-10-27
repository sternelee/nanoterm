#!/usr/bin/env bash
# Applies nanoterm's embedding patch to the pristine fx submodule.
# Run automatically by zig build; safe to run repeatedly.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$root/vendor/fx"
patch_file="$root/patches/fx/nanoterm-embed.patch"

if [ ! -f "$fx/src/main.zig" ]; then
    echo "The fx submodule is not checked out." >&2
    echo "Run: git submodule update --init vendor/fx" >&2
    exit 1
fi

# embedded.zig is nanoterm's entry point into fx core. Its presence means the
# patch is already applied (prepare runs before every compile).
if [ -f "$fx/src/embedded.zig" ]; then
    exit 0
fi

git -C "$fx" apply --3way "$patch_file"
echo "Applied patches/fx/nanoterm-embed.patch to vendor/fx" >&2
