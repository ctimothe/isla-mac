@AGENTS.md

# Claude Code extras

Everything shared with other agent tools is in `AGENTS.md`. Only what is
specific to Claude Code is here.

## Skills

- **`.agents/skills/apple-design`** (also `.claude/skills/apple-design`) is the
  design and motion bar for Isla: springs, gestures, materials, typography,
  Reduce Motion. Load it before designing or reviewing any surface or motion.

## The visual lab

```bash
bash Scripts/visual-lab.sh                          # every surface → build/visual-lab
bash Scripts/visual-lab.sh <dir> <Case>             # one case, e.g. VisualLabGlyphsTests
```

Headless renders of every surface, state and animation, with an accessibility
dump per render. No window is ordered on screen, no event is posted, the
screen is never captured, Isla is never launched, defaults come from a volatile
domain, the pasteboard is private, and every network request is refused. It is
the safe way to look at a change while the owner is using the Mac. Every lab
case skips itself in `./scripts/check` (`ISLA_VISUAL_OUT` unset).

## Subagents

- Subagents never launch Isla, never set a `DI_*` hook, never `dlopen` the
  helper and never drive the live app or a player. Only the main session does,
  and only when the owner has handed the Mac over for live checks.
- Tests must never reach a real player or the owner's real defaults.
- Brief a subagent with the spec section it touches and the tests that hold
  it; it reads `docs/development/spec.md`, not old plans.
