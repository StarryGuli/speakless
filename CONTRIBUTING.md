# Contributing to Speakless

Thanks for helping! Issues and pull requests are welcome, in English or 中文.

## Development setup

Requirements: macOS 13+, Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

```bash
git clone https://github.com/StarryGuli/speakless.git
cd speakless/app
swift build            # quick compile check
./build.sh             # build/Speakless.app
open build/Speakless.app
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for permissions, debugging and the benchmark.

## Workflow

1. Open an issue first for anything larger than a small fix, so we can agree on the approach.
2. Branch from `main`: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`.
3. Keep PRs focused; describe what changed and how you tested it (macOS version, which provider).
4. Use [Conventional Commits](https://www.conventionalcommits.org/): `feat: …`, `fix: …`, `docs: …`.
5. A PR must compile with `swift build` without new warnings.

## Code style

- Swift, SwiftUI first; AppKit only where SwiftUI can't do it (event taps, panels, Accessibility).
- UI colours and hover/focus styles go through `Theme.swift`, not ad-hoc values.
- Anything non-standard toward a provider (extra endpoints, fields) must be an opt-in per-provider option, never default.
- Never log or commit API keys, audio, or dictated text.

## Prompts and the benchmark

Prompt changes (`DefaultPrompts`) should be checked with `tests/siliconflow/bench.py` and the result noted in the PR. Use your own API key; do not commit recordings.

## Reporting bugs / security

Bugs: use the issue template. Security issues: see [SECURITY.md](SECURITY.md); do not open a public issue.
