# nanoterm for the phone

What a workstation's nanoterm holds, on a phone. A thin client, and thin is
the point: iOS cannot fork, so a phone cannot run a shell — the Mac runs the
tab, the relay (`--relay PORT`, see [the top-level README](../README.md))
says what changed, and this shows it. A native nanoui app, one language for
every platform nanoui covers (iOS now, Android after).

## Running it

```sh
# On the Mac: the tabs, on the loopback, with a token.
zig build run -- --relay 4789

# On the phone (Xcode's Simulator; `open -a Simulator` or boot one first),
# with the token nanoterm printed at startup:
cd mobile && ./dev.sh --host 127.0.0.1 --port 4789 --token THE-32-CHAR-TOKEN
```

`./dev.sh` is the whole Zig-side dance: Zig 0.17.0 cannot build a program for
iOS as it ships (its `std.process` says iOS may replace its process image, so
`std.Io` wants `posix_spawn`'s `/dev/null`, which std leaves out on iOS), so
nanoui's `tools/ios/zig-lib.sh` makes a lib folder with that one line fixed
and prints the `--zig-lib=` flag that uses it. `./dev.sh build` stops at the
bundle (`zig-out/ios/nanoterm.app`), `./dev.sh native` builds the same
program as a window of this Mac's, which is the quickest way to try a change
to the client without a Simulator in the way.

Through a tunnel (Tailscale, a Cloudflare tunnel, `ssh -L`), `--host` is the
tunnel's address on the phone and the port is the same: the relay itself
never leaves the loopback of the Mac.

With **Cloud** picked on the connect screen, the phone reaches the Mac from
anywhere without a tunnel of your own. It dials a relay you run —
[alma-relay](../alma-relay) is one, a Cloudflare Worker over a Durable
Object — at `wss://<host>/c/<token>/phone`, and the Mac, which dialled the
same relay, is at the other end. The address and the token are the relay's:
the same 32 characters, matched by their hash, sent in the clear only to
the relay that already holds them.

That tunnel is encrypted but not authenticated: Android builds here have no
certificate store to check the relay against, so the phone accepts whatever
certificate the relay presents. The token is what stands for the relay's
identity — keep it to yourself, and remember that whoever runs the relay can
read what the tunnel carries.

## What it shows, and what it does

The tabs and what happens in them, rendered as what they are rather than as
the JSON they arrived in: a command and what it printed, an agent's answer,
a tab closing. `fdwatch` reads the socket on the main thread as the desktop
relay's `visual_host.zig` reads its own — no polling, no second thread — and
a debug build says what it received on the console
(`xcrun simctl launch --console-pty …`), which is how a Simulator run is
checked.

The composer at the bottom sends too: **Run** executes a command in the tab
the relay shows (a real shell, on the Mac), **Ask** sends it to that tab's
agent, and Return sends either. The keyboard comes up on open — a phone
opens to a place to type — and nanoui gives the field UIKit's software
keyboard and keeps `Context.safe_area` clear of it.

While something is running — a command in that tab's shell, or the agent's
turn — a **Stop** button sits in the header, and only then: tapping it sends
`interrupt`, and the relay does what Esc does at the Mac (the agent's turn
is cancelled, the shell gets an interrupt; a command that was running ends
with exit 130). The phone learns what is running from the `block` and
`turn` events themselves, so a tab already busy when the phone connects
offers Stop too.

A permission the agent is waiting on arrives as a card above the composer,
with its options as buttons: tapping one sends the answer, and the card goes
when the relay says the question was answered (here or at the Mac).

`src/tests_phone.zig` covers the parts that decide what a tap means — a
turn's permission becoming a card, an answered one taking it away, the tab
the composer points at, the exact JSON sent for `run`/`ask`/`answer`/
`interrupt`, Stop offered while a block or a turn runs and gone when both
are done, and a typed command being sent, echoed, and cleared — with
`zig build test`.

### On a phone over USB

The relay listens on the workstation's loopback, so a phone on a cable
reaches it through adb's own tunnel — no Wi-Fi, no LAN IP, no firewall:

```sh
# 1. the relay, on the Mac
nanoterm --relay 4789            # or NANOTERM_RELAY_TOKEN=... nanoterm --relay 4789

# 2. the phone's localhost:4789 is the Mac's
adb reverse tcp:4789 tcp:4789

# 3. install and start it, its arguments as intent extras
cd mobile && zig build -Dtarget=aarch64-linux-android
adb install -r zig-out/android/nanoterm.apk
adb shell am start -n com.justrach.nanoterm/android.app.NativeActivity \
  --es nanoui.arg.0 --host  --es nanoui.arg.1 127.0.0.1 \
  --es nanoui.arg.2 --port  --es nanoui.arg.3 4789 \
  --es nanoui.arg.4 --token --es nanoui.arg.5 <32 hex>
adb logcat -s nanoui              # what the app prints (a debug build does)
```

Build it **for debug** (the default): nanoui only lets a debuggable build
read intent extras — a release build ignores them, since any app could send
them — so a `-Doptimize=ReleaseSafe` APK starts with no token and says so.
A release build needs the host, port and token from somewhere of its own (a
connect screen, saved), which is the next thing this app wants.

### The APK

`zig build -Dtarget=aarch64-linux-android`
produces `zig-out/android/nanoterm.apk` (NativeActivity, the same
`main.zig` and the same composer). Running it needs a system image in
`ANDROID_HOME` (`sdkmanager "system-images;android-35;google_apis;arm64-v8a"`)
and `sh tools/android/emulator.sh` from nanoui's package, or a phone over
`adb`; `zig build run-android -Dtarget=aarch64-linux-android` installs it
and shows its log. `Content.page` is still off the table on mobile, so the
native UI is the whole app there too.
