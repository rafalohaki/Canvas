---
name: canvas-upstream-sync
description: Use whenever syncing Canvas with upstream Paper (dev/26.2) or Canvas OG — bumping paperCommit/canvasCommit, resolving patch conflicts after upstream updates, the upstream.sh script, canvas/ vs local/ partitioning, Folia→Paper migration patterns, or absorbing new upstream patches. Triggers on "upstream", "update Paper", "paperCommit", "canvasCommit", "sync upstream", "rebase", "conflict", "upstream.sh", "Folia to Paper", "absorb patch", "canvas/ vs local/", "dual upstream".
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

# Canvas Upstream Sync (Dual: Paper + Canvas OG)

Canvas upstreams from **two** sources:
- **PaperMC/Paper** (`dev/26.2`) — primary base, frequent updates via `paperCommit`
- **CraftCanvasMC/Canvas** (OG) — our "parent" fork, also upstream frequently via `canvasCommit`

**Never treat as single upstream.** No Folia dependency — Folia's region threading
was absorbed as Canvas-original base patches.

The `paperCommit` (+ `canvasCommit` to add) in `gradle.properties` pins exact states.
Merges the former `/canvas-dual-upstream` skill.

## canvas/ vs local/ Partitioning Strategy

Every patch layer is split into `canvas/` and `local/` subdirs:
- `canvas/` = patches absorbed from CraftCanvasMC/Canvas OG (our parent fork)
- `local/`  = our delta / fixes / opinions on top of OG

Applies to all patch locations:
- `canvas-server/minecraft-patches/base/{canvas,local}/`
- `canvas-server/minecraft-patches/sources/{canvas,local}/`
- `canvas-server/paper-patches/base/{canvas,local}/`
- `canvas-api/paper-patches/base/{canvas,local}/`

Rules:
- Changes that came from Canvas OG → put resulting patch in `canvas/`.
- Our delta / fixes / opinions → `local/`.
- When absorbing from OG later, compare against `canvas/`, not `local/` — never
  let OG changes blindly overwrite `local/` work.
- `roadmap.md` tracks what's Paper vs Canvas OG absorbed vs our local.

## upstream.sh Commands (extend for dual)

Current (Paper only):
```bash
./upstream.sh update    # bumps paperCommit
./upstream.sh apply
./upstream.sh rebuild
./upstream.sh full
```

**Target (implement):**
```bash
./upstream.sh paper update|apply|rebuild|full
./upstream.sh canvas update|absorb|diff|full     # for CraftCanvasMC/Canvas
```

Until then, manually manage `canvasCommit` + fetch from `upstream` remote.

## paperCommit Bumping Workflow (Paper direct upstream)

1. **Update commit**: `./upstream.sh update` — fetches latest `dev/26.2` HEAD, updates `gradle.properties`
2. **Apply patches**: `./upstream.sh apply` — `./gradlew applyAllPatches --no-configuration-cache`
3. **Fix rejects** — patches that fail to apply need manual fixing (see below)
4. **Rebuild patches**: `./upstream.sh rebuild` — regenerate clean patch files
5. **Verify**: `./gradlew :canvas-server:compileJava && ./gradlew test`
6. **Commit**: stage updated `gradle.properties` + regenerated patches

Always use `--no-configuration-cache` after any commit bump.

## Absorbing New Canvas OG Patches

When CraftCanvasMC/Canvas publishes new patches we want:
1. Fetch from `upstream` remote (or add it): `git fetch upstream`
2. Identify the new OG commits/patches (diff against current `canvasCommit`)
3. Apply on POST-AT state (Canvas ATs replicate visibility changes, so OG patches apply cleanly)
4. Place absorbed patches in `canvas/` subdir, renumber sequentially
5. Regenerate with `git format-patch` from POST-AT state for correct `index` lines
6. Bump `canvasCommit` in `gradle.properties`
7. Update `roadmap.md` — mark as Canvas OG absorbed

## Resolving Patch Conflicts

### Base patch rejects (git am --3way)
```bash
./gradlew applyMinecraftBasePatches -Dpaperweight.debug=true --no-configuration-cache
# If it fails:
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
git am --abort
git apply --rej <path-to-failing-patch>
# Fix .rej files manually
git add -A
git am --continue
# Regenerate the base patch with correct index lines:
git format-patch -1 HEAD -o <patch-dir>/
```

### Source patch rejects
Failed source patches move to `canvas-server/minecraft-patches/rejected/`.
```bash
ls canvas-server/minecraft-patches/rejected/
# For each rejected patch, open it and fix the hunk context/line numbers
# Then move it back:
mv canvas-server/minecraft-patches/rejected/<file>.patch canvas-server/minecraft-patches/sources/
./gradlew applyMinecraftSourcePatches
```

### Conflict resolution patterns
- **ATs survive rebases better than patches** — if a visibility change keeps
  conflicting, move it to `build-data/canvas.at` instead of a patch hunk.
- **Strip `index` lines** from patches imported from another upstream (blob
  hashes don't exist here) — regenerate with `git format-patch` from POST-AT.
- **Stable context lines** win on rebase — anchor hunks on signatures, not body.
- **One concern per patch** — split mixed-concern patches before rebase.

## Folia→Paper Migration Patterns (from roadmap.md)

Canvas absorbed Folia's region threading patches as Canvas-original base patches.
Key technique when absorbing patches from a different upstream:

1. **Strip `index` lines** from source patches (blob hashes from other upstream don't exist here)
2. **Apply on POST-AT state** — Canvas ATs replicate Folia's `private → public` changes, so Folia patches apply cleanly on POST-AT
3. **Regenerate with `git format-patch`** from POST-AT state — this creates correct `index` lines for `git am --3way`
4. **Renumber** — insert absorbed patches before Canvas-original patches, renumber Canvas ones

## Pre-Update / Patch Roulette Scripts

For major upstream updates, Canvas has a patch roulette workflow:

```bash
./pre_update.sh                    # Apply patches, enable git file patches, rebuild, move to _unapplied
# ... do the update / patch roulette ...
./prepare_for_patch_roulette.sh    # Move patches back, apply, disable git file patches, rebuild, push
```

`pre_update.sh` moves source patches to `sources_unapplied/` and enables
`gitFilePatches = true` for git-based application. `prepare_for_patch_roulette.sh`
reverses this and pushes to the Patch Roulette service.

## Checking What Changed Upstream (Dual)

```bash
# Paper
git ls-remote https://github.com/PaperMC/Paper.git refs/heads/dev/26.2
grep paperCommit gradle.properties

# Canvas OG
git ls-remote https://github.com/CraftCanvasMC/Canvas.git
grep canvasCommit gradle.properties   # (add this)

# DeepWiki (preferred for understanding changes)
deepwiki_ask_question(repoName="PaperMC/Paper", question="What changed in dev/26.2 since commit X?")
deepwiki_ask_question(repoName="CraftCanvasMC/Canvas", question="Summarize changes in recent commits for region threading / scheduler")
```

## Pitfalls (Dual Upstream Edition)

1. **Always use `--no-configuration-cache`** after any commit bump.
2. **Don't force-push** — patches + history are shared.
3. **Test after every sync** (see `/canvas-verify-build`).
4. **Keep `roadmap.md` + `canvasCommit`** updated — track Paper vs Canvas OG absorbed vs our local.
5. **AT + POST-AT** — adding AT often requires base patch regeneration. ATs survive rebases better than patches.
6. **canvas/ vs local/** — never let OG changes blindly overwrite `local/` work. Compare against `canvas/`.
7. **No Folia dependency** — Folia patches are absorbed, not synced. Don't track Folia as upstream.
8. Use DeepWiki for both repos before assuming what changed.
