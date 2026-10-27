#!/usr/bin/env bash
# Updates vendor/fx to the latest upstream main and reapplies nanoterm's
# embedding patch. Review and commit the updated patch and submodule pointer.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fx="$root/vendor/fx"
patch_file="$root/patches/fx/nanoterm-embed.patch"

if [ ! -f "$fx/src/main.zig" ]; then
    echo "The fx submodule is not checked out." >&2
    echo "Run: git submodule update --init vendor/fx" >&2
    exit 1
fi

expected=(
    src/builtins/mcp.zig
    src/core/cli/cli_ask.zig
    src/core/config/config_runtime.zig
    src/core/config/settings_store.zig
    src/core/terminal/native_session.zig
    src/embedded.zig
)
unexpected=0
while read -r status path; do
    [ -n "$path" ] || continue
    case " ${expected[*]} " in
        *" $path "*) ;;
        *) echo "Refusing to discard unexpected submodule change: $status $path" >&2; unexpected=1 ;;
    esac
done < <(git -C "$fx" status --porcelain)
if [ "$unexpected" -ne 0 ]; then
    exit 1
fi

git -C "$fx" fetch origin
git -C "$fx" checkout -B main origin/main
git -C "$fx" reset --hard origin/main
git -C "$fx" apply --3way "$patch_file"
git -C "$fx" diff --cached --binary --src-prefix=a/ --dst-prefix=b/ > "$patch_file"

echo "vendor/fx is now at $(git -C "$fx" rev-parse --short origin/main)." >&2
echo "Reapplied and refreshed patches/fx/nanoterm-embed.patch." >&2
echo "Run zig build test, then commit the submodule pointer and patch." >&2
