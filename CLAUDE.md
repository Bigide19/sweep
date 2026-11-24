# Sweep

macOS menu bar app that finds regenerable build output and caches, shows what each one costs to rebuild, and deletes only what you pick.

## Layout

| Path | Contents |
|---|---|
| `app/` | Swift package. `SweepCore` (all logic), `SweepApp` (menu bar UI), `SweepCLI` (rule verification) |
| `docs/` | Design background and rule reference (Korean) |

## Commands

Run from `app/`:

```bash
swift build -c release              # build all products
./scripts/build-app.sh --run        # bundle Sweep.app and launch it
./scripts/build-app.sh --install    # copy the bundle to /Applications
.build/release/sweep verify         # rule regression test
.build/release/sweep scan           # list candidates
.build/release/sweep clean --yes    # delete default-selected candidates
```

The bundle is required. The status item does not claim a menu bar slot when run as a bare executable.

## Core design

Rules compete by priority. Highest wins; deny wins on a tie. Broad deny sits at low priority, narrow allow exceptions sit above it. This is what lets `node_modules/**/build` be denied as package code while `node_modules/*/android/build` stays allowed as Gradle output.

Rules only see path shape. Whether a `build` directory is output or hand-written source is decided by the safety guards in `SweepCore/Guards.swift`, never by rules alone.

Background and rationale: `docs/architecture.md`.

## Conventions

- **Adding a rule**: edit `DefaultRuleSet.swift`, add an expectation to `runVerify()` in `SweepCLI/main.swift`, then run `sweep verify`. Do not ship a rule change without a passing verify.
- **`lockProcesses` vs `lockCommands`**: the first matches the executable basename exactly (case-insensitive), the second substring-matches the whole command line. Using substring matching for both produced false positives, e.g. `/opt/homebrew/bin/node` matching `brew`.
- **Deletion is permanent by design.** Moving to the trash leaves disk usage unchanged, which defeats the purpose. History is appended to `~/Library/Application Support/Sweep/history.jsonl`.
- **Unknown app caches are never deleted.** Anything under `~/Library/Caches` that is not whitelisted shows its size and stays locked.
- Korean comments in 합니다체, written generously - explain intent and non-obvious decisions.

## Knowledge lives here

Sweep-specific context belongs in this repo (`CLAUDE.md`, `docs/`), not in home-session memory.
