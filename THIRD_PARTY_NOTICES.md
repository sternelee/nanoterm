# Third-party notices

nanoterm's own source code is licensed under the MIT License in
[`LICENSE`](LICENSE). The material below keeps its own copyright and license.

## nanoui

nanoterm is built on [nanoui](https://github.com/justrach/nanoui), Copyright (c)
2026 Rach Pradhan, under the MIT License. nanoui carries its own notices for
mygo (MIT) and GPUI (Apache 2.0) in its
[`THIRD_PARTY_NOTICES.md`](https://github.com/justrach/nanoui/blob/main/THIRD_PARTY_NOTICES.md).

## fx

The built-in agent is compiled from [fx](https://github.com/vercel-labs/fx),
by Vercel Labs, under the Apache License 2.0. The source is checked out as
the `vendor/fx` submodule at revision
[`e71a663b95a46ce88de6a1d73da833f1851303e4`](https://github.com/vercel-labs/fx/commit/e71a663b95a46ce88de6a1d73da833f1851303e4),
with nanoterm's embedding and configuration APIs added by
[`patches/fx/nanoterm-embed.patch`](patches/fx/nanoterm-embed.patch). Its
original license is preserved at [`vendor/fx/LICENSE`](vendor/fx/LICENSE).
nanoterm does not launch or require a separately installed fx executable.

## CodeGraff and Harness (external license)

nanoterm uses these from [CodeGraff](https://github.com/justrach/codegraff) and
[Harness](https://github.com/justrach/harness):

- **The Codegraff Dark and Light palettes** (`src/theme.zig`), the composer,
  turns folded into a summary, and the look of native visuals, after
  [Harness](https://github.com/justrach/harness).
- **`show_visual`**: nanoterm answers the same tool, with the same Luau nodes,
  so a visual written for Harness shows in nanoterm.

These parts are derived from CodeGraff and come under the license CodeGraff
ships with: CodeGraff's **modified GNU AGPLv3**, Copyright (C) 2026 Rach
Pradhan and Yu Xi Lim. That license, not MIT, stays their license. It is kept
here as the original, verbatim, in
[`third_party/licenses/CodeGraff-LICENSE.txt`](third_party/licenses/CodeGraff-LICENSE.txt)
(from CodeGraff
[`389b261`](https://github.com/justrach/codegraff/blob/389b26182fef0b8070d9a976505286d693876b6c/LICENSE)).
Harness is distributed under the same modified AGPLv3 terms.

nanoterm's MIT license covers nanoterm's own code. It does not extend to fx,
CodeGraff or Harness.

## Luau

`show_visual` runs [Luau](https://luau.org), the language by Roblox (MIT).
nanoterm interprets it with its own implementation in `src/luau/`, written for
nanoterm; it includes no code from Luau.

## Marks

The model picker and Settings show monochrome marks, drawn to PNG
(`src/marks/`). The agents' marks and those of Anthropic, OpenAI and xAI are
Harness's (its `crates/ui/assets/icons`). The other model makers' marks are
from [LobeHub Icons](https://github.com/lobehub/lobe-icons), as Harness ships
them; LobeHub Icons is MIT licensed, Copyright (c) 2023 LobeHub, and its
license is kept at `src/marks/LICENSE.lobehub`. The marks identify each agent
and each model's maker and imply no affiliation or endorsement.
