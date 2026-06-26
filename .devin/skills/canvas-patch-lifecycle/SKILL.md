---
name: canvas-patch-lifecycle
description: Use whenever applying, editing, creating, or rebuilding Canvas patches — base patches (git am --3way, index lines), source patches (per-file, patch command), feature patches, applyAllPatches, rebuildPatches, rbp.sh, the POST-AT application cycle, Weaver task flow. Triggers on "apply patches", "rebuild patches", "patch reject", "git am failed", "add a patch", "edit a patch", "base patch", "source patch", "feature patch", "fixupSourcePatches", "rbp", "POST-AT", "runCanvasSetup".
triggers:
  - user
  - model
argument-hint: "[patch-type]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
  - write
---

# Canvas Patch Lifecycle

Canvas uses a 3-layer patch system on top of Paper (dev/26.2), with dual-upstream
(Paper + Canvas OG). **Always read `roadmap.md`, `gradle.properties`, and
`/canvas-upstream-sync`** first.

Patch counts (current): 14 base, 142 sources, 2 features, 9 paper-server base,
7 paper-api base. Origins are partitioned into `canvas/` (absorbed from OG) vs
`local/` (our delta) under each layer.

## Patch Layers (minecraft-patches) — Dual Upstream

| Layer | Dir (partitioned) | Apply method | Notes |
|-------|-------------------|--------------|-------|
| **Base** | `.../base/{canvas,local}/` | `git am --3way` | Architecture. `canvas/` = from OG, `local/` = ours. Needs valid `index` lines from POST-AT. |
| **Source** | `.../sources/{canvas,local}/` | `patch` | Per-file. Keep hunks small for rebase safety. |
| **Feature** | `.../features/` (or local/) | git commits | Optional / experimental. |

Same structure under:
- `canvas-server/paper-patches/base/{canvas,local}/` + `files/`
- `canvas-api/paper-patches/base/{canvas,local}/`

See `/canvas-patch-authoring` and `/canvas-upstream-sync`.

## The POST-AT Application Cycle (critical)

Base patches are applied **after** Canvas ATs (`build-data/canvas.at`) via the
`runCanvasSetup` cache. This is why Folia-absorbed patches apply cleanly: Canvas
ATs replicate Folia's `private → public` changes, so patches apply on POST-AT
state where the visibility is already open.

ATs survive rebases better than patches — prefer AT over a patch hunk for
visibility changes.

### Weaver Task Flow (runCanvasSetup → base → source → feature)

```
runCanvasSetup
  → Paper source → Paper ATs → Paper patches → Canvas ATs → cache repo (POST-AT state)
applyMinecraftBasePatches
  → clones cache (POST-AT) → git clean -fxd → git reset --hard HEAD → git am --3way *.patch
applyMinecraftSourcePatches
  → applies 142 per-file patches with `patch` on top
applyMinecraftFeaturePatches
  → applies feature patches (git commits)
```

`applyAllPatches` runs the full pipeline: Paper + Canvas (base → source → feature).

**If a base patch lacks `index` lines**, `git am --3way` fails with
"sha1 information is lacking or useless". Fix: regenerate from POST-AT state
using `git format-patch`.

## Common Gradle Tasks

```
./gradlew applyAllPatches                    # Full pipeline (Paper + Canvas)
./gradlew applyMinecraftBasePatches          # Just base (14 patches)
./gradlew applyMinecraftSourcePatches        # Just source (142 patches)
./gradlew applyMinecraftFeaturePatches       # Just features (2 patches)
./gradlew rebuildPatches                     # Rebuild all from applied source
./gradlew rebuildMinecraftSourcePatches      # Rebuild source patches only
./gradlew fixupMinecraftSourcePatches        # Normalize before rebuild (fixupSourcePatches)
```

Paper best practice: run `fixupSourcePatches` before `rebuildPatches` to
normalize hunk formatting.

## Editing Workflow

### To edit an existing source patch
1. `./gradlew applyAllPatches` — construct `canvas-server/src/minecraft/java/`
2. Edit the file in `canvas-server/src/minecraft/java/`
3. `./rbp.sh` — auto-detects changes, runs fixup + rebuild tasks
4. Verify the regenerated `.patch` file looks correct

### To add a new base patch
1. `./gradlew applyAllPatches`
2. Make your change in `canvas-server/src/minecraft/java/`
3. `git add -A && git commit -m "Your patch description"`
4. `git format-patch -1 HEAD -o canvas-server/minecraft-patches/base/{canvas,local}/` — generates patch **with index lines**
5. Rename to next number: `00NN-Description.patch`
6. Verify: `./gradlew applyMinecraftBasePatches`

### To add a new source patch
1. `./gradlew applyAllPatches`
2. Edit file in `canvas-server/src/minecraft/java/`
3. `./gradlew fixupMinecraftSourcePatches && ./gradlew rebuildMinecraftSourcePatches` — generates per-file `.patch`

### To add a feature patch
1. `./gradlew applyAllPatches`
2. Make multi-file changes, commit in `canvas-server/src/minecraft/java/`
3. `git format-patch -1 HEAD -o canvas-server/minecraft-patches/features/`
4. Rename to `00NN-Description.patch`

## Fixing Rejects

### Base patch rejects (`git am --3way`)
- `git am --abort`, `git reset --hard`, `git clean -f`
- Apply manually: `git apply --rej <patch>`, fix `.rej` files, `git add -A`, `git am --continue`
- Or use `scripts/apatch.sh <file>` — tries `git am -3`, falls back to `wiggle` for conflict resolution

### Source patch rejects
- Failed patches move to `canvas-server/minecraft-patches/rejected/`
- Fix the hunk in the `.patch` file manually (adjust line numbers / context)
- Re-run `./gradlew applyMinecraftSourcePatches`

## rbp.sh Flags

- `./rbp.sh` — auto-detect changed dirs, rebuild only those
- `./rbp.sh --force` — rebuild all patches regardless of detected changes
- `./rbp.sh --gradle` — also run `rebuildFoliaSingleFilePatches` (legacy name, still used for build.gradle.kts patches)
- `./rbp.sh --debug` — pass `-Dpaperweight.debug=true` to Gradle

## Verification Commands (always run after patch changes)

```bash
./gradlew applyAllPatches --no-configuration-cache   # clean apply
./gradlew :canvas-server:compileJava                 # compiles
./rbp.sh                                             # patches regenerate cleanly
git diff --stat                                       # review what changed
./gradlew test                                        # unit tests pass
```

If `applyAllPatches` fails, **stop and fix** — do not proceed to build.

## Pitfalls

1. **Never strip `index` lines from base patches** — `git am --3way` needs them.
2. **Source patches use `patch`, not `git am`** — no index lines needed, but context must match.
3. **ATs apply before base patches (POST-AT)** — if you need a field public, add to `build-data/canvas.at`, not the patch. ATs survive rebases better.
4. **`filterPatches = false`** in `build.gradle.kts` — empty patches are retained, don't delete them.
5. **Patch numbering must be sequential** — gaps break `git am` ordering.
6. **Run `fixupSourcePatches` before `rebuildPatches`** — normalizes hunk formatting (Paper convention).
