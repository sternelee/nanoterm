<p align="center">
  <img src="docs/images/agent-light.png" alt="nanoterm in CodeGraff Light: Agent's turn folded into a summary, with a native visual" width="760">
</p>

<h1 align="center">nanoterm</h1>

<p align="center">A terminal of blocks with a coding agent beside you, drawn on the GPU.</p>

<p align="center">Built on <a href="https://github.com/justrach/nanoui"><strong>nanoui</strong></a>, with <a href="https://fx.sh/">fx(040d5bbbf214e35fdcdfc4e365773bae09a5eb23)</a> compiled in as <strong>Agent</strong>. Claude Code and other external agents connect over ACP; Pi speaks its own RPC mode.</p>

<p align="center">
  <img alt="macOS · Linux" src="https://img.shields.io/badge/macOS%20·%20Linux-555">
  <img alt="Built-in Agent and ACP agents" src="https://img.shields.io/badge/agents-built--in%20Agent%20%2B%20ACP-8a6bd1">
  <img alt="Agent built in" src="https://img.shields.io/badge/Agent-built%20in-44cc11">
  <img alt="Built in Zig 0.17" src="https://img.shields.io/badge/built%20in-Zig%200.17-f7a41d?logo=zig&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="#download">Download</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#blocks">Blocks</a> ·
  <a href="#agent">Agent</a> ·
  <a href="#visuals">Visuals</a> ·
  <a href="#ssh">SSH</a> ·
  <a href="#keys">Keys</a> ·
  <a href="#credits">Credits</a>
</p>

Your own zsh, with each command a block, in the manner of
[Warp](https://www.warp.dev). One input runs commands or asks the agent, and
the agent's commands run as blocks beside yours.

## Download

**macOS** (Apple silicon, macOS 13+):
[download nanoterm](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-macos-arm64.dmg),
open the disk image, and drag nanoterm to Applications. Each
[release](https://github.com/justrach/nanoterm/releases) lists the image's
SHA-256. Releases are built by
[`.github/workflows/release.yml`](.github/workflows/release.yml), and
`sh macos/package.sh` builds the same disk image locally.

**Windows** (10 1809 or later, x86_64 or arm64):
[x86_64](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-windows-x86_64.zip)
or [arm64](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-windows-aarch64.zip):
unzip and run `nanoterm.exe`. The shell is PowerShell (7 if it's installed,
else Windows PowerShell) on a pseudo console, cut into blocks as zsh is on
macOS. The program isn't signed yet, so SmartScreen asks once ("More info",
then "Run anyway"). `sh tools/package-windows.sh` builds the zips.

**Linux** (x86_64 or arm64, GTK 3):
[x86_64](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-linux-x86_64.tar.gz)
or [arm64](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-linux-aarch64.tar.gz).

## Get started

nanoterm builds on its own. It fetches nanoui 0.8.0, pinned by commit in
`build.zig.zon`, and checks out the built-in Agent's fx core as the
`vendor/fx` submodule:

```sh
git clone --recurse-submodules https://github.com/justrach/nanoterm
cd nanoterm
# Already cloned? git submodule update --init vendor/fx
zig build run
zig build run -- --cwd ~/code/app --run "git status" --agent claude --ask "What changed?"
zig build test        # VT, zsh blocks, ACP fakes, Agent config, the classifier, Luau and visuals
```

The build applies `patches/fx/nanoterm-embed.patch` to the pristine
submodule automatically. To move fx to the latest upstream main and reapply
that patch, run `scripts/update-fx.sh`, then build and commit the updated
submodule pointer and patch.

Working on nanoui at the same time? In a `--recursive` clone of
[nanoui](https://github.com/justrach/nanoui), nanoterm lives under `apps/`.
Build it there against the nanoui next to it, with your changes, using
`--fork`:

```sh
cd nanoui/apps/nanoterm
zig build run --fork=../..
```

<p align="center">
  <img src="docs/images/palette-dark.png" width="760" alt="The ⌘P launcher in CodeGraff Dark: sessions, history, actions and commands">
  <br><sub>The ⌘P launcher in CodeGraff Dark. Synthetic example sessions.</sub>
</p>

## Blocks

Your own zsh runs on a pseudo-terminal. A small rc file sources your
`.zshrc`, then marks each prompt, the start of a command's output and its
end with the exit status (OSC 133), and the working directory (OSC 7). Each
command becomes a block: where it ran (directory, git branch), the command,
its output in color (16, 256 and 24-bit SGR; carriage returns redraw lines
as a terminal does), and how it ended, with a bar on the left for running,
succeeded or failed. Pagers are set to `cat` so output stays in the block.

While a command runs, what you type is its input; ⌃C stops it.

## Full-screen programs

vim, less, top and the like switch to the alternate screen; from there
their bytes drive a grid of cells (`screen.zig`, parsed by `screen_vt.zig`)
that fills the pane, as xterm would: cursor movement, scrolling regions,
inserted and deleted lines and characters, SGR colors and attributes
(bold, italics, underline, inverse, dim, strikethrough), wide characters,
DEC line drawing, and answers to what programs ask (the cursor's position,
the terminal's kind, its colors, so vim picks a dark scheme). Keys go to the
program as xterm sends them (application cursor keys, function keys, ⌃
combinations), the wheel scrolls as the arrow keys do, and ⌘V pastes,
bracketed when the program asks. ⌘ shortcuts stay nanoterm's. When the
program leaves its screen, or ends, the pane shows the blocks again.

## One input, commands or requests

As in Warp, there is one input. nanoterm tells a command from a request
as you type, Warp's way: local rules decide whether the text is a command
(a program on your PATH with flags, pipes or paths), a request (everyday
English or a trailing `?`), or needs your choice. A pill before the input
shows where Return goes and why (`auto`, `choice`, or `locked` after ⌘I
or a click); Esc on an empty input goes back to detecting. Classification
stays on this machine and does not use a model or an account.

- **Suggestions**: the latest matching command from your history (zsh's,
  read only, then nanoterm's own in `~/Library/Application Support/nanoterm/history`)
  is drawn faintly after the caret; → or Tab takes it.
- **Completion**: Tab completes commands, files and folders, git
  subcommands and branches; several candidates open a menu (↑↓, Tab or ↩).
- **Slash commands**: for an external ACP agent, `/` lists its commands
  (`available_commands_update`) with what each does.
- **Agent and model**: the chip at the right of the input (or ⌘⇧M) picks
  the agent and its model. External agents expose their ACP config options;
  for Agent, enter a model or configure providers in Settings. Model
  changes apply to the next Agent turn without restarting the app.
- **Blocks**: a failed command offers **Fix with …** and **Explain**;
  hovering a block offers run again, ask the agent about it (it goes with
  your next prompt as context, shown as a chip), and copy. ⌘↑ ⌘↓ select
  blocks.
- **Pictures**: ⌘V with an image (a screenshot, image files copied in
  Finder) or the paperclip attaches it; chips above the input show what
  goes with the next prompt (✕ leaves one out), sent as native Agent image
  attachments or ACP image blocks when the selected agent takes them.
- **Markdown files**: `cat README.md` draws the file as Markdown; hovering
  the block offers **Raw** to see it as text.
- **Palette**: ⌘P is a launcher: one search over your open sessions, the
  session history (every conversation, kept across launches in
  `sessions.jsonl` beside the command history), actions, recent commands,
  and the agent. Tab narrows it to one kind; the row chosen is previewed at
  the side (a conversation's prompt and reply, a pane's latest work). ↩ on
  a conversation of this run goes to it; on an older one, asks it again.

## How it looks

The input is Harness's composer: a rounded pill with the pictures going
with the prompt as thumbnails, the text, and a row of controls (attach,
shell or agent, the agent and model, a round send button that becomes a
stop square while something runs); where you are and the keys sit
quietly under it. Agents' answers show the local pictures they link
(`![alt](/path/shot.png)`) inline, captioned; a click opens one.

The colors are Harness's: CodeGraff Dark and CodeGraff Light, warm
neutrals with an amber accent, following the system's appearance until
you choose one in the palette (⌘P, "light mode", "dark mode"); the choice
is kept for the next launch.

Text is set in **Geist** and code and output in **JetBrains Mono**, when
they are installed (else SF Pro and SF Mono). Agents' answers are
Markdown, drawn as such: headings, airy paragraphs with **bold**,
_italics_, `inline code` and links in place, bullet, numbered and task
lists, quotes, tables, and code blocks with their language, syntax colors
and a Copy button. Each turn shows your question and the agent's answer
under their own avatars.

## Agent

**Agent is built in**: the agent runtime, native tools, sessions,
providers, MCP host and Skills are compiled into nanoterm. It does not
launch `fx acp` or `fx ask`, and needs no fx executable, Node.js or libfx.
The Settings page manages custom
OpenAI-compatible providers, stdio/HTTP MCP servers and Skills in expandable
panels; every configured MCP server can list the tools it actually exposes.
Everything lives in Agent's own configuration files in `~/.fx`.

Settings also offers **Pi**, alongside those; the agent picker (⌘⇧M)
switches the pane to any installed agent.

Pi speaks its own RPC mode, not ACP: nanoterm runs `pi --mode rpc
--no-session` and reads the same JSON lines Pi's SDK does (`src/pi.zig`).
Its model, thinking level, slash commands and tool calls are Pi's, and the
chosen model goes as `--provider` and `--model`.

**Claude Code, Codex, opencode, Grok, Devin and Hermes** remain available
as external ACP agents. For those, nanoterm is the ACP client:

- `initialize` with the file system and terminal capabilities, `session/new`
  in the shell's directory, `session/prompt`, `session/cancel` (⌃C, Esc);
- `session/update`: messages (light Markdown), thoughts, tool calls with
  their status and output, plans;
- `session/request_permission`: asked in the conversation, with the agent's
  options as buttons;
- `fs/read_text_file`, `fs/write_text_file`;
- `terminal/create` … `release`: the commands the agent runs show as blocks
  in its turn, as in Warp.

For Pi it is an RPC client instead (`src/pi.zig`): `get_state`,
`get_available_models`, `get_available_thinking_levels`, `get_commands`,
`prompt`, `set_model`, `set_thinking_level`, `abort`, and Pi's own events
(`message_update`, `tool_execution_*`, `agent_settled`). Pi runs its tools
itself, so those show in its turn too, but it has no ACP permission
prompts and runs no commands in nanoterm's terminal. Its visuals
(`show_visual`) would need an MCP server entry in Pi's own configuration,
which nanoterm does not write.

## Visuals

As in Harness, an agent can answer with something you can use instead of
a paragraph: a small interactive visual in its turn (compare plans, move a
slider, see the trade-off). nanoterm gives every agent its own MCP server
(`nanoterm --mcp SOCKET TOKEN`): external agents through ACP's `mcpServers`,
and Agent as a host-issued stdio server, offering one
tool, `show_visual`, with Harness's title, script and rules, so the same
scripts work in both. The script is Luau: it keeps state in locals and
returns a render function that builds `ui.column`, `row`, `text`, `stat`,
`chart` (bars), `button`, `toggle`, `slider` and `rule`, drawn in
nanoterm's own look. nanoterm adds what explains things better than
paragraphs: `heading`, `note`, `flow` (numbered steps, the active one lit,
clickable), `tabs`, `list`, `table`, `code`, `badge`, `progress`, and
`group` (a titled panel); the tool's description tells agents to show
structure rather than prose. Controls call back into the script and it renders
again, with no model turn; Reset starts it over.

Luau runs in nanoterm's own interpreter (`src/luau/`, in Zig): Lua 5.1 with
Luau's additions (compound assignment, `continue`, if-expressions, backtick
strings, type annotations), the string, table, math and utf8 libraries,
and nothing that reaches outside: no files, processes, network, clock,
output or code loading. Each visual has its own machine with budgets for
steps (a runaway script stops within about 20 ms), memory (16 MiB) and
depth, and Harness's limits per render (512 nodes, depth 24, 8 KiB of
text, 256 chart values). Styling is refused, not ignored. The server
checks the script (setup and the first render) before nanoterm shows it,
so the agent hears at once what is wrong. Visuals come in on a socket in a
directory only you can open, with a token per agent.

When an agent fails to start, the conversation says why, with the agent's
own last words. Claude Code refuses to run inside another Claude Code
session: start nanoterm from a terminal that isn't one.

## SSH

`ssh host` (or ⌘P → SSH hosts, from your `~/.ssh/config`) opens the
connection shared (ControlMaster, in a folder only you can open). Once
you have signed in, the session's bar offers to set nanoterm up there, for
this session only (one line sent to the remote shell; nothing is written on
the host): from then on each command you run is a block of its own, with
its status and the remote folder, and the input knows it is on the host
(commands, unless you ask something). Ask the agent and it works there:
its prompt says which host and folder, the commands it runs through
nanoterm run on the host, and the files it reads and writes through
nanoterm are the host's, all over the shared connection, never stopping
for a password.

## Splits and tabs

Ghostty's model, as Harness has it: a tab holds a tree of split panes,
each pane a session of its own (its shell, its timeline, its input, its
agent). A new pane starts in the focused pane's directory; unfocused panes
are dimmed; dividers drag, and a double-click equalizes. The keys live in
the menus (Shell, Window), as Ghostty's do.

## Finding, zooming, long output

⌘F opens a find bar over the panes: every match in the focused pane's
commands and output is highlighted as you type, the current one brighter;
↩ and ⇧↩ step through them, scrolling to each (and showing the hidden lines
of a long block when the match is among them). ⌘= and ⌘- make every text
bigger or smaller, ⌘0 puts it back. Scrolled into a long output, the
block's command stays pinned at the top of the pane (a click goes to its
start); scrolled up while output comes, a "Jump to latest" pill goes back.

## Linux and Windows

nanoterm runs on Linux as on the Mac (on Windows, nanoui runs; nanoterm needs
ConPTY first). Command shortcuts there leave Control to the programs a
terminal runs (^D, ^W, ^T mean something to vim and the shell), so they take
Ctrl+Shift, as Ghostty's do: every binding is written once (`src/binds.zig`)
and each platform gets its own, in the menus, the keys and the labels shown.

## Keys

| macOS          | Linux                     |                                                                  |
| -------------- | ------------------------- | ---------------------------------------------------------------- |
| Return         | Return                    | run, or send to the agent (the pill says which)                  |
| ⌘I             | Ctrl+Shift+I              | shell ⇄ agent, chosen until Esc on an empty input                |
| → / Tab        | → / Tab                   | take the suggestion; Tab completes                               |
| ⌘P             | Ctrl+Shift+P              | command palette                                                  |
| ⌘⇧M            | Ctrl+Shift+M              | agent and model                                                  |
| ⌘F             | Ctrl+Shift+F              | find in the pane's blocks                                        |
| ⌘= ⌘- ⌘0       | Ctrl+= Ctrl+- Ctrl+0      | bigger, smaller, actual size                                     |
| ⌘↑ ⌘↓          | Ctrl+Shift+↑ ↓            | select the previous / next block                                 |
| ⌘D / ⌘⇧D       | Ctrl+Shift+O / E          | split right / down                                               |
| ⌘] / ⌘[        | Ctrl+Shift+] / [          | next / previous pane                                             |
| ⌘⌥ arrows      | Ctrl+Alt+arrows           | the pane in that direction                                       |
| ⌘⌃ arrows      | Ctrl+Shift+Alt+arrows     | move the divider                                                 |
| ⌘⌃=            | Ctrl+Shift+Alt+=          | equalize the panes                                               |
| ⌘⇧↩            | Ctrl+Shift+Enter          | zoom the pane                                                    |
| ⌘W             | Ctrl+Shift+W              | close the pane (asks if a command runs); the last closes the tab |
| ⌘T             | Ctrl+Shift+T              | new tab                                                          |
| ⌘⇧] ⌘⇧[, ⌘1…⌘9 | Ctrl+PageDown/Up, Alt+1…9 | next / previous tab, tab n                                       |
| ⌘K             | Ctrl+Shift+K              | clear the blocks                                                 |
| ⌃C             | Ctrl+C                    | stop the command or the agent's turn                             |
| ↑ ↓            | ↑ ↓                       | history                                                          |

Launch options: `--cwd DIR`, `--run CMD` (repeat), `--agent NAME`
(`agent`, `claude`, `codex`, `opencode`, `grok`, `devin`, `hermes`, `pi`),
`--ask PROMPT`, `--split right|down` (repeat).

From a shell, [`tools/nt`](tools/nt) (copy it to `~/.local/bin`) opens a
window here, `nt DIR` in a folder, and `nt FILE` in the file's folder showing
it, Markdown drawn as Markdown. Files opened with nanoterm from the Finder
(Open With) or `open -a nanoterm FILE` open the same way, each in a tab.

## License

nanoterm's own code is licensed under the [MIT License](LICENSE). The vendored
fx source keeps its **Apache-2.0** license. The palettes and UI parts derived
from CodeGraff/Harness keep their original **modified AGPLv3**, kept verbatim
in [`third_party/licenses`](third_party/licenses/CodeGraff-LICENSE.txt); see
[third-party notices](THIRD_PARTY_NOTICES.md).

## Credits

- **[nanoui](https://github.com/justrach/nanoui):** windows, layout, text,
  selection and the renderers. nanoui itself owes its design to
  [mygo](https://github.com/egoist/mygo) by
  [egoist](https://github.com/egoist), and to
  [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) by
  [Zed Industries](https://zed.dev).
- **[Warp](https://www.warp.dev):** commands as blocks, and one input for
  commands and requests.
- **[Ghostty](https://ghostty.org):** splits, tabs and their keys.
- **[fx](https://fx.sh/):** the built-in Zig Agent runtime, native tools,
  providers, MCP and Skills, from Vercel Labs (Apache-2.0).
- **[Harness](https://github.com/justrach/harness):** the CodeGraff colors, the
  composer, turns folded into a summary, and native visuals from Luau
  (`show_visual`). External agents use ACP the way Harness does.

<p align="center"><sub>Built in Zig 0.17 on <a href="https://github.com/justrach/nanoui">nanoui</a> · <a href="LICENSE">MIT</a> · <a href="THIRD_PARTY_NOTICES.md">third-party notices</a></sub></p>
