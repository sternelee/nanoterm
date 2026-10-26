# nanoterm agent guide

## Repository map

- This is one Zig 0.17 application, not a workspace of app packages. `build.zig` builds `src/main.zig` into `nanoterm` and also defines test, benchmark, and video steps.
- `src/` contains the terminal, shell/PTY integration, ACP client, workspace/split UI, and views. Platform-specific process code is split between `src/proc_posix.zig` and `src/proc_windows.zig`; shared key bindings are defined once in `src/binds.zig`.
- `src/luau/` is nanoterm's own sandboxed Luau interpreter for agent-provided visuals. `src/marks/` contains bundled image assets and their license notice.
- `bench/` is a separate terminal-engine benchmark, with small Zig and Rust runners. It is not part of the application runtime; see `bench/README.md` before changing it.
- `macos/package.sh` and `tools/package-*.sh` produce release artifacts. Release orchestration and platform checks live in `.github/workflows/release.yml` and `.github/workflows/ci.yml`.

## Build and test

Use Zig **0.17.0** (the minimum in `build.zig.zon` and the version used in CI). The build fetches the nanoui revision pinned in `build.zig.zon`.

```sh
zig build                         # compile the application
zig build run                     # run the application
zig build test                    # full test suite on macOS
zig build test -Dtest-filter=NAME # only tests whose names contain NAME
```

Use the focused filter while iterating, then run the full suite before finishing. There is no separate repository lint or type-check task; compilation and tests are the configured checks.

Tests use temporary home directories, but integration tests execute real local programs. On Unix they require zsh and Python 3. Linux CI additionally installs GTK 3, fonts, vim, less, git, curl, and a virtual display; use its package list in `.github/workflows/ci.yml` when setting up a minimal environment. The Linux CI-equivalent test sequence is:

```sh
zig build test-bin --prefix zig-out/linux
xvfb-run -a zig-out/linux/bin/nanoterm-tests
```

On Windows, create `\tmp` before testing, then build and run the test binary directly (PowerShell/ConPTY coverage requires Windows; Wine skips the PowerShell tests):

```powershell
New-Item -ItemType Directory -Force -Path \tmp | Out-Null
zig build test-bin --prefix zig-out/windows
zig-out/windows/bin/nanoterm-tests.exe
```

`src/tests.zig` is the non-Windows test root; `src/tests_windows.zig` is the Windows root. A new standalone test file must be imported by the appropriate root to run. Keep platform-independent coverage visible to both roots where applicable. Windows CI also exercises the application and self-update beyond `zig build test`; consult that workflow for changes to startup, settings, packaging, or updates.

For changes to `src/vt.zig`, `src/screen_vt.zig`, or `src/screen.zig`, `bench/README.md` documents the correctness and performance check. `sh bench/run.sh` clones and builds external benchmark engines, generates workloads, and writes a new report; it requires Zig 0.17, Zig 0.15.2, and cargo.

## Local nanoui development

A standalone checkout uses the commit-pinned nanoui dependency. When this repository is at `apps/nanoterm` inside a recursive nanoui checkout, pass `--fork=../..` to build against the adjacent nanoui source instead:

```sh
zig build run --fork=../..
```

Do not casually change the dependency URL, commit, or hash in `build.zig.zon`; ordinary builds rely on that pin.

## Generated and licensed files

- Do not edit build output in `.zig-cache/`, `zig-out/`, `bench/.cache/`, or generated `bench/results/*/screen-*` files. Packaging scripts also generate archives, checksums, app bundles, and `zig-out/package/manifest.json`.
- Preserve `third_party/licenses/CodeGraff-LICENSE.txt` and `src/marks/LICENSE.lobehub` verbatim. Not all derived material is covered by the repository's MIT license; read `THIRD_PARTY_NOTICES.md` before changing or reusing the Codegraff palettes, Harness-derived UI/visual material, or bundled marks.

## Safety and data handling

- Shell commands, agent terminals, ACP file operations, and SSH file/command forwarding can affect real local or remote systems. Tests and manual checks must not use a developer's actual home, shell history, agent credentials, SSH configuration, or remote hosts.
- Agent visuals execute untrusted Luau. Keep their interpreter isolated from files, processes, network, clock, output, and dynamic code loading, and preserve the execution/resource limits and per-agent socket authentication described in `README.md` and implemented under `src/luau/`, `src/mcp_server.zig`, and `src/visual_host.zig`.
- Settings, session history, update metadata, and agent-related files may contain private paths, prompts, or account data. Do not print or commit real user data, credentials, or access tokens in diagnostics, fixtures, screenshots, or test output.

## Done means

- The focused test covering the change passes, followed by the full platform-appropriate suite.
- Application changes compile with `zig build`; shared process, shell, binding, or settings behavior is checked against the relevant platform CI coverage rather than assumed portable.
- No generated artifacts or user-local state are included in the change, and licensing notices remain intact when derived material is touched.
