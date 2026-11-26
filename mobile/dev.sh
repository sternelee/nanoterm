#!/bin/sh
# The phone's nanoterm in the booted Simulator. Zig 0.17.0 cannot build a
# program for iOS as it ships; nanoui's tools/ios/zig-lib.sh makes a lib
# folder with one line fixed and prints the flag that uses it, which goes
# before every other `zig build` argument.
#
#   ./dev.sh              build and run, in the booted Simulator
#   ./dev.sh build        build only (zig-out/ios/nanoterm.app)
#   ./dev.sh native       the same program as this Mac's window
#   ./dev.sh --host H --port P --token T     args for the app
set -eu
cd "$(dirname "$0")"

package="$(ls -d zig-pkg/nanoui-*/ 2>/dev/null | head -1)"
if [ -z "$package" ]; then
	echo "dev.sh: no nanoui in zig-pkg: run 'zig build' once to fetch it" >&2
	exit 1
fi
libflag="$(sh "$package/tools/ios/zig-lib.sh")"

case "${1:-run}" in
build)
	exec zig build $libflag -Dtarget=aarch64-ios-simulator
	;;
native)
	shift
	exec zig build run-native -- "$@"
	;;
run)
	# The app's arguments come after `run`'s: `-Dtarget` and the rest go
	# to the build, `--host` and the rest to the app.
	exec zig build $libflag run -Dtarget=aarch64-ios-simulator -- "$@"
	;;
*)
	echo "dev.sh: run, build or native" >&2
	exit 1
	;;
esac
