---
name: canvas-refactor-patterns
description: Safe refactoring patterns for Canvas that survive dual upstreams, frequent rebases, and our own architecture evolution. Minimal diff, layer respect, AT preference, stable identities. Covers core principles, impact assessment, refactoring patterns, rebase-safe rules, architecture change protocol, verification, and anti-patterns. Triggers on "refactor", "move code", "rename", "extract", "restructure", "future proof refactor", "rebase-safe", "impact assessment", "change architecture".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
---

# Canvas Refactor Patterns

Canvas changes architecture often and upstreams from two sources (Paper +
Canvas OG). These patterns keep changes small and rebaseable.

## Core Principles

1. **Minimal diff** — every line in a patch is a future conflict. Change as
   few lines as possible.
2. **Respect layers** — base/ for architecture, sources/ for per-file fixes,
   features/ for optional. Never mix concerns.
3. **Ground in source** — read the actual current source before refactoring.
   MC 26.2 APIs change; never guess from training data.
4. **Verify after every change** — apply → compile → test → rebuild patches.
   No exceptions.
5. **AT over patch** — for visibility changes, use Access Transformers
   (`build-data/canvas.at`) instead of patching every call site. See
   `/canvas-at-guard`.

## Impact Assessment

Before refactoring, assess the blast radius:

```bash
# How many patches touch this file?
grep -rl "<FileName>" canvas-server/minecraft-patches/

# How many source patches reference this class?
grep -rl "ClassName" canvas-server/minecraft-patches/sources/

# Is this class referenced in base patches?
grep -rl "ClassName" canvas-server/minecraft-patches/base/

# Does any AT target this class?
grep "ClassName" build-data/canvas.at

# Is this in the API surface (plugin-visible)?
grep -rl "ClassName" canvas-api/

# Check if Canvas OG has a version of this (dual upstream)
grep -rl "ClassName" canvas-server/minecraft-patches/base/canvas/
grep -rl "ClassName" canvas-server/minecraft-patches/sources/canvas/
```

Impact levels:
- **Low** — only source patches, no base, no AT, no API. Safe to refactor.
- **Medium** — base patches or ATs involved. Coordinate with patch regeneration.
- **High** — API surface or core subsystem (scheduler, chunk system, region
  threading). Requires full verification + roadmap update.

## Patch Layers (strict)

| Layer | Dir | Method | When | Rebase risk |
|-------|-----|--------|------|-------------|
| base | `minecraft-patches/base/{canvas,local}/` | `git am --3way` | Architecture, big replaces, new subsystems | medium |
| source | `minecraft-patches/sources/{canvas,local}/` | `patch` (per-file) | Single file tweaks, bug fixes | high |
| feature | `minecraft-patches/features/` | git commits | Optional add-ons | low |
| paper-api | `canvas-api/paper-patches/base/{canvas,local}/` | `git am` | API additions/changes | medium |

Do not put behavior change in a base patch "because it's convenient".

## canvas/ vs local/ Partition

- Anything that came from Canvas OG → `canvas/`
- Our exclusive work, opinions, fixes, config → `local/`

When refactoring something in `canvas/`, treat it as "mostly upstreamed" —
changes there should be justifiable as "we improved the absorbed code".

## Refactoring Patterns

### Extract Method

- Extract into new method in same file first (source patch ok).
- Keep call sites stable — don't rename the caller.
- If the extracted thing becomes a new subsystem → promote to base patch +
  new files.
- Mark with Paper convention: `// Paper start - extract <desc>` / `// Paper end`.

### Move Class

- High risk. Do in a dedicated base patch.
- Update all references in the same patch (huge diff, do rarely).
- Package moves: one base patch + update all imports.
- Consider: can the class stay where it is? Moving creates a large rebase
  surface for every upstream sync.

### Rename

- Avoid renaming public API methods/fields that upstream or plugins call.
- For internal: add alias first, migrate callers, then delete old in a
  separate patch. Three-patch sequence:
  1. Add new name + delegate to old
  2. Migrate all call sites to new name
  3. Remove old name
- Class renames: same — big rebase surface. Only with strong justification.

### Change Architecture

- Must be in `base/local/` (or `base/canvas/` if absorbing from OG).
- One base patch per architectural change.
- Update `roadmap.md` with the decision and rationale.
- Update `AGENTS.md` patch layout table if patch count changes.
- See `/canvas-architecture-evolution` for ADR pattern.

### Replace Upstream Implementation

Template: `0013-Replace-Moonrise-Executor` (DeepWiki: Canvas chunk executor).
- One base patch.
- Remove old, add new, keep interface compatible.
- Update ATs if needed for the new impl.
- Document why in commit message + `roadmap.md`.
- Full apply + compile + test + runDev verification.

## Rebase-Safe Rules

1. **Small hunks** — each hunk should be minimal. Large hunks fail on context
   drift.
2. **Stable context lines** — use method signatures and class declarations as
   context, not body lines that change often.
3. **One concern per patch** — never mix refactoring with behavior change.
4. **No reformatting** — don't reformat surrounding code. Reformatting
   changes every line → every hunk conflicts on next upstream.
5. **Prefer ATs** — for visibility changes, AT is one line in `canvas.at`
   vs. N lines across M patches.
6. **Prefer fully-qualified imports** in vanilla classes to prevent patch
   conflicts (Paper convention — reduces import-block conflicts during
   rebases).
7. **Don't rename/move in source patches** — renames and moves belong in base
   patches where all references can be updated atomically.

## When Architecture Changes

### Our own architecture changes

1. Update `roadmap.md` — document the decision, rationale, and impact.
2. Label patches clearly — `[Canvas]` or `[local]` in patch headers.
3. Renumber carefully — if inserting a new base patch, all subsequent patches
   shift. Update `AGENTS.md` patch layout table.
4. Test the full pipeline — `applyAllPatches` → compile → test → `runDev`.
5. Update `AGENTS.md` if patch counts or layout change.

### Upstream architecture changes (Paper or Canvas OG)

1. Use DeepWiki (`PaperMC/Paper` or `CraftCanvasMC/Canvas`) to understand the
   new design before acting.
2. Decide: absorb into our `canvas/` layer, or override in `local/` with our
   version.
3. One dedicated base patch for the adaptation.
4. Update `roadmap.md` with the decision.
5. Check if ATs need updating — upstream may have changed visibility of
   members we AT'd.

## Verification Commands

After any refactor:

```bash
# 1. Apply all patches cleanly
./gradlew applyAllPatches --no-configuration-cache

# 2. Compile
./gradlew :canvas-server:compileJava
./gradlew :canvas-api:compileJava

# 3. Test
./gradlew test

# 4. Rebuild patches
./rbp.sh

# 5. Check no new rejects
ls canvas-server/minecraft-patches/rejected/ 2>/dev/null

# 6. Runtime verification (if behavior changed)
./gradlew runDev
```

## After Refactor Checklist

- [ ] `applyAllPatches --no-configuration-cache` clean
- [ ] `compileJava` (server + api) passes
- [ ] `test` passes
- [ ] `rbp.sh` runs without errors
- [ ] No new rejects in `minecraft-patches/rejected/`
- [ ] Patches in correct layer + `canvas/` or `local/` subdir
- [ ] DeepWiki or local source citations in commit message
- [ ] `roadmap.md` updated if architecture changed
- [ ] `AGENTS.md` updated if patch layout changed
- [ ] Relevant skill updated if pattern is new

## Anti-Patterns

- **"Quick source patch for big change"** — will explode on next upstream.
  Promote to base patch.
- **Mixing `canvas/` and `local/` changes in one commit** — blurs the dual
  upstream boundary.
- **Renaming things only for "cleanliness"** — every rename is a rebase
  liability. Only rename with strong functional reason.
- **Large context in source patches** — context lines that change frequently
  cause hunk failures. Use stable anchors (signatures, class declarations).
- **Forgetting to regenerate base patches after AT change** — AT changes
  alter POST-AT state; base patches must be regenerated from new POST-AT.
- **Reformatting surrounding code** — changes every line, breaks every hunk
  on next upstream sync.
- **Guessing APIs from training data** — MC 26.2 APIs change. Always ground
  in current source.
- **Skipping verification** — "it compiles" is not enough. Apply → compile
  → test → rebuild → check rejects.

## Architecture Migration Patterns

When moving from one architecture base to another (e.g., Folia-based →
Paper-based), follow these patterns:

### Assess the scope
- Map all patches that depend on the old architecture.
- Identify ATs that replicate the old architecture's visibility changes.
- Check if the new base already provides some of the changes (avoid duplicates).

### Absorb patches incrementally
- Don't migrate everything at once — one patch at a time, verify each.
- Apply on POST-AT state so visibility changes are already in place.
- Strip `index` lines from patches imported from the old architecture
  (blob hashes don't exist in the new base).
- Regenerate with `git format-patch` from POST-AT for correct `index` lines.

### Handle AT migration
- Move visibility changes from patches to AT files where possible.
- Folia-originated ATs → `build-data/folia.at`
- Canvas-original ATs → `build-data/canvas.at`
- See "AT Migration" pattern below.

### Update documentation
- `roadmap.md` — ADR entry for the migration.
- `AGENTS.md` — patch layout table if counts change.
- Affected skills — architecture map, threading, scheduler.

## Patch Merging

When to merge multiple small patches into one:

### Triggers
- Upstream Canvas merged patches (e.g., 14→7 base patches) and we want to
  stay aligned with their structure.
- Several patches always fail/succeed together — merging reduces rebase
  surface area.
- Patches share the same logical concern but were split prematurely.
- Patch count is growing and maintenance burden is increasing.

### Procedure
```bash
# 1. Apply all patches to get clean source
./gradlew applyAllPatches --no-configuration-cache

# 2. Go to the POST-AT cache repo
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/

# 3. Apply the patches you want to merge (in order)
git am --3way 0001-First.patch
git am --3way 0002-Second.patch

# 4. Squash into one commit
git reset --soft HEAD~2
git commit -m "Merged: First + Second — <unified description>"

# 5. Generate the merged patch
git format-patch -1 HEAD -o canvas-server/minecraft-patches/base/{canvas,local}/

# 6. Rename to the correct number, renumber subsequent patches
# 7. Update AGENTS.md patch layout table
# 8. Full verification pipeline
```

### When NOT to merge
- Patches touch different subsystems that evolve independently.
- One patch is `canvas/` and another is `local/` — don't cross partitions.
- Upstream might split them again — merging creates divergence.

## AT Migration

When to move patch-based access changes to an AT file:

### Triggers
- A visibility change (private→public) is inlined in a patch hunk and keeps
  conflicting on rebase.
- Multiple patches need the same visibility change — AT is one line vs N
  patch hunks.
- Upstream changed visibility of a member we're patching — AT is easier to
  update than regenerating patch hunks.

### Procedure
1. Identify the member: `grep -rn "private\|protected" <file>` in the patch.
2. Add an AT line to the appropriate file:
   - Folia-originated → `build-data/folia.at`
   - Canvas-original → `build-data/canvas.at`
3. Remove the visibility change from the patch hunk (keep the behavior change).
4. Clean the runCanvasSetup cache: `rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/`
5. Re-apply: `./gradlew applyAllPatches --no-configuration-cache`
6. Regenerate affected base patches from POST-AT state.
7. Verify: compile + test + rbp.

### When NOT to migrate to AT
- The change is more than visibility (behavior, logic) — keep in patch.
- The member is added by our patch (not upstream) — AT only applies to
  existing upstream members.
- See `/canvas-at-guard` for the full AT vs patch decision matrix.

## Cross-References

- `/canvas-at-guard` — AT syntax, modifier options, POST-AT dependency cycle
- `/canvas-patch-authoring` — patch layer rules, base patch generation
- `/canvas-architecture-evolution` — ADR pattern, migration strategy, breaking changes
- `/canvas-verify-build` — full verification pipeline
- `/canvas-upstream-sync` — resolving conflicts during upstream sync

Sources: DeepWiki (Canvas CRS scheduler, Weaver task flow), `roadmap.md`,
`canvas-server/minecraft-patches/base/0013-Replace-Moonrise-Executor.patch`.
