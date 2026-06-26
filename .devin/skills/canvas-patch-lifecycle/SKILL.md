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

Base patches are applied **after** Canvas ATs (`build-data/canvas.at` +
`build-data/folia.at`) via the `runCanvasSetup` cache. This is why
Folia-absorbed patches apply cleanly: Canvas ATs (including `folia.at`)
replicate Folia's `private → public` changes, so patches apply on POST-AT
state where the visibility is already open.

ATs survive rebases better than patches — prefer AT over a patch hunk for
visibility changes.

### Weaver Task Flow (runCanvasSetup → base → source → feature)

```
runCanvasSetup
  → Paper source → Paper ATs → Paper patches → Canvas ATs (canvas.at + folia.at) → cache repo (POST-AT state)
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

## Patch Health Scoring

Assess whether a patch is healthy (low maintenance burden) or needs attention:

### Health score factors

| Factor | Healthy | Needs attention |
|--------|---------|-----------------|
| **Apply success** | Applies cleanly every time | Frequently rejects, needs manual fixing |
| **Reject count** | 0 rejects on upstream sync | Multiple rejects per sync cycle |
| **Context stability** | Hunks anchored on signatures (stable) | Hunks anchored on body lines (churn) |
| **Upstream drift** | Patch still matches upstream structure | Upstream has diverged significantly |
| **Size** | Small, focused (one concern) | Large, mixed concerns |
| **Age** | Recently reviewed/updated | Not touched in 3+ upstream syncs |
| **AT dependency** | No AT dependency, or AT is stable | Depends on AT that upstream may change |
| **Test coverage** | Has a test exercising the change | No test, untested behavior |

### Scoring
- **Green (healthy)**: applies cleanly, stable context, one concern, has test.
- **Yellow (watch)**: occasional rejects, but fixable in <5 min. Monitor.
- **Red (action needed)**: frequent rejects, unstable context, mixed concerns.
  Action: split, refactor context anchors, or merge with a related patch.

### Assessment commands
```bash
# Check if a patch applies cleanly (fresh state)
rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
./gradlew applyAllPatches --no-configuration-cache 2>&1 | grep -i "reject\|fail"

# Check patch size (lines)
wc -l canvas-server/minecraft-patches/base/{canvas,local}/*.patch | sort -n

# Check if any rejects accumulated
ls canvas-server/minecraft-patches/rejected/ 2>/dev/null

# Check AT dependencies
grep -f canvas-server/minecraft-patches/base/{canvas,local}/0001-*.patch \
     build-data/canvas.at build-data/folia.at
```

### Actions by score
- **Green** → no action. Review quarterly.
- **Yellow** → add a note in `roadmap.md`. Review at next upstream sync.
- **Red** → schedule a refactor: split/merge, stabilize context, add test.
  Document the decision as an ADR in `roadmap.md`.

## Reject Resolution Patterns

Common reject patterns and how to fix them:

### Pattern: "Context not found" (hunk context drift)
**Symptom**: `patch` or `git am` reports "hunk failed" because surrounding
lines changed upstream.
**Fix**: Open the `.rej` file, find the new location of the changed code in
the current source, update the hunk context lines to match. Use stable
anchors (method signatures, class declarations) instead of body lines.

### Pattern: "sha1 information is lacking" (base patch)
**Symptom**: `git am --3way` fails with "sha1 information is lacking or useless".
**Fix**: The base patch is missing `index` lines (blob SHA1s). Regenerate
from POST-AT state:
```bash
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
git format-patch -1 HEAD -o <patch-dir>/
```

### Pattern: "File not found" (file moved/renamed upstream)
**Symptom**: Patch targets a file that no longer exists at that path.
**Fix**: Find the new location: `grep -rl "<ClassName>" canvas-server/src/minecraft/java/`.
Update the patch header (`diff --git a/old/path b/new/path`) and hunk paths.
If the file was split into multiple files, split the patch accordingly.

### Pattern: "Already applied" (duplicate change)
**Symptom**: Patch fails because the change is already in the source (upstream
added the same fix).
**Fix**: Check if the patch is now redundant. If so, remove it and update
`AGENTS.md` + `roadmap.md`. If partially redundant, trim the patch to only
the remaining delta.

### Pattern: "AT dependency broken" (visibility changed upstream)
**Symptom**: Patch fails because a field/method it accesses is no longer
private (upstream made it public) or was renamed.
**Fix**: If upstream made it public, remove the AT entry (see `/canvas-at-guard`
→ AT Validation). If renamed, update the AT entry and the patch references.

### Pattern: "Fuzz factor" (offset but applicable)
**Symptom**: Patch applies with a fuzz factor warning (lines offset by N).
**Fix**: Usually OK — the patch applied. But rebuild it to update context:
`./rbp.sh --force`. Fuzz > 3 lines means the context is drifting — consider
stabilizing the anchors.

### Pattern: "Multiple rejects in one patch" (patch too large)
**Symptom**: Several hunks reject in the same patch.
**Fix**: The patch is too large or touches unstable areas. Split it into
smaller patches (one concern each). See `/canvas-patch-authoring` → Patch
Merging (in reverse — split instead of merge).

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
