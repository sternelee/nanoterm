# nanoterm agent guide

## Repository map

- The root is one Zig application, not a workspace of packages. `build.zig` compiles `src/main.zig` into `nanoterm` and defines the `run`, `test`, `test-bin`, `bench`, and `video` steps; its options are `-Dtest-filter`, `-Dstrip`, and `-Dversion`.
- `src/` holds the terminal, shell/PTY integration, ACP client, workspace/split UI, and views. Platform process code is split between `src/proc_posix.zig` and `src/proc_windows.zig`; key bindings are defined once in `src/binds.zig`. `src/threads.zig` is the Github thread watcher (`gh` polling; one read-only proposal turn per thread, a Run-gated working turn).
- `src/luau/` is nanoterm's own sandboxed Luau interpreter for agent visuals; `src/marks/` holds bundled image assets and their license notice.
- `mobile/` is a separate nanoui app (`mobile/build.zig`, `mobile/build.zig.zon`) for iOS and Android. It imports `../src/markdown.zig` and `../src/highlight.zig`, so changes there affect the phone build; see `mobile/README.md` and `mobile/PACKAGING.md`.
- `bench/` is a standalone terminal-engine benchmark (Zig and Rust runners) outside the application runtime; read `bench/README.md` before changing it.
- `macos/package.sh` and `tools/package-*.sh` produce release artifacts, `tools/manifest.sh` writes the update feed, and `mobile/package*.sh` packages the phone app; platform CI and release orchestration live in `.github/workflows/ci.yml` and `.github/workflows/release.yml`.
- User-facing behavior is documented by section in `README.md` (`## Agent`, `## Github threads`, `## Visuals`, `## SSH`, `## Phone`, `## Linux and Windows`, `## Keys`); cite and update those sections rather than restating behavior elsewhere.

## Build and test

Use Zig **0.17.0** (the `minimum_zig_version` in `build.zig.zon`, and the version every CI job pins). The nanoui dependency is pinned by commit and hash in `build.zig.zon`; do not change that URL, commit, or hash as part of unrelated work, and note both the desktop and phone builds resolve that same pin.

`zig build` runs `scripts/prepare-fx.sh` before compiling, which applies `patches/fx/nanoterm-embed.patch` to the `vendor/fx` submodule. Check the submodule out first, or the build stops with a submodule error:

```sh
git submodule update --init vendor/fx
```

```sh
zig build                         # compile the application
zig build run                     # run it (passthrough args go to the program)
zig build test                    # full suite on the host platform
zig build test -Dtest-filter=NAME # only tests whose names contain NAME
zig build test-bin --prefix zig-out/linux   # tests as a program, for another machine
```

Use the filter while iterating, then run the full suite before finishing. CI runs no formatter, linter, or separate type-check job: `zig build` and `zig build test` are the configured checks, so a clean compile plus a green suite is the whole gate.

Tests use temporary home directories, but integration tests run real programs. On Unix they need zsh and Python 3. The Linux job builds with `test-bin` and runs the result under a virtual display; its apt list (`libgtk-3-0t64`, `fonts-dejavu-core`, `fonts-noto-core`, `xvfb`, `xauth`, `zsh`, `vim`, `less`, `python3`, `git`, `curl`, `ca-certificates`, `xz-utils`) is the minimal environment:

```sh
zig build test-bin --prefix zig-out/linux
xvfb-run -a zig-out/linux/bin/nanoterm-tests
```

On Windows, create `\tmp` first (tests write pictures there), then build and run the test binary directly; ConPTY and PowerShell coverage only runs there (Wine skips those tests):

```powershell
New-Item -ItemType Directory -Force -Path \tmp | Out-Null
zig build test-bin --prefix zig-out/windows
zig-out/windows/bin/nanoterm-tests.exe
```

The Windows job also runs the application headless and exercises self-update; read `.github/workflows/ci.yml` before changing startup, settings, packaging, or updates. Treat CI as the authority on platform-specific behavior instead of assuming macOS behavior is portable.

### Test roots

`src/tests.zig` is the non-Windows test root and `src/tests_windows.zig` is the Windows one. Both pull tests in with `_ = @import("tests_foo.zig");`, so a new test file that is not imported by a root never runs. Keep platform-independent coverage visible to both roots.

### Benchmark and phone

- For `src/vt.zig`, `src/screen_vt.zig`, or `src/screen.zig` changes, `bench/README.md` describes the correctness and performance check. `sh bench/run.sh` clones and builds external engines and writes a new report under `bench/results/<date>/`; it needs Zig 0.17, Zig 0.15.2 (Ghostty), and cargo (Alacritty).
- For the phone app, `cd mobile && zig build test` tests the relay client on the host, `./dev.sh` drives the Simulator build, and `mobile/PACKAGING.md` covers packaging. See `mobile/README.md` for why Zig needs nanoui's `tools/ios/zig-lib.sh` there.

## Generated and licensed files

- Do not edit build output or caches: `.zig-cache/`, `zig-out/`, `zig-pkg/`, `bench/.cache/`, `bench/zig-out/`, `bench/zig-cache/`, `bench/target/`, or generated `bench/results/*/screen-*` files. Packaging scripts also generate archives, checksums, app bundles, and `zig-out/package/manifest.json`.
- Do not edit `vendor/fx` by hand. The build applies `patches/fx/nanoterm-embed.patch` to it, so a dirty submodule working tree after a build is expected and must not be committed; only the pinned commit pointer and the patch belong in the change. Move fx with `scripts/update-fx.sh`, then `zig build test` before committing the updated pointer and patch.
- Preserve `third_party/licenses/CodeGraff-LICENSE.txt` and `src/marks/LICENSE.lobehub` verbatim. Not all derived material is covered by the repository's MIT license; read `THIRD_PARTY_NOTICES.md` before changing or reusing the Codegraff palettes, Harness-derived UI/visual material, or the bundled marks.

## Safety and data handling

- Shell commands, agent terminals, ACP file operations, and SSH file/command forwarding reach real local or remote systems. Tests and manual checks must never use a developer's real home, shell history, agent credentials, SSH configuration, or remote hosts.
- The Github watcher runs `gh` against whatever repository is watched, and its Run action makes an agent branch and commit in that checkout. Tests must not call `gh`, bind the watcher's host, or press Run on a real repository.
- Agent visuals execute untrusted Luau. Keep the interpreter isolated from files, processes, network, clock, output, and dynamic code loading, and preserve its step/memory/depth budgets and the per-agent socket token described in `README.md` and implemented in `src/luau/`, `src/mcp_server.zig`, and `src/visual_host.zig`.
- Settings, session history, update metadata, and agent files can hold private paths, prompts, or account data. Do not print or commit real user data, credentials, or tokens in diagnostics, fixtures, screenshots, or test output.

## Done means

- The focused test for the change passes, followed by the full suite for the platform(s) touched (`zig build test` on macOS, the CI sequences above on Linux and Windows), and `cd mobile && zig build test` plus any affected packaging when phone code changes.
- Application changes compile with `zig build`; shell, process, binding, settings, and update behavior is checked against the matching CI job rather than assumed portable.
- No generated artifacts, cache output, `vendor/fx` patch residue, or user-local state are included in the change, and third-party notices stay intact when derived material is touched.
