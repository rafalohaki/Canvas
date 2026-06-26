---
name: canvas-weaver-internals
description: Use whenever debugging Weaver/Paperweight task internals, the runCanvasSetup cache, applyMinecraftBasePatches/SourcePatches/FeaturePatches task flow, patchFile/patchRepo/patchDir mechanics, RebuildGitPatches/RebuildBaseGitPatches config, or writing custom Weaver tasks. Triggers on "weaver", "paperweight", "runCanvasSetup cache", "applyMinecraftBasePatches", "taskCache", "RebuildGitPatches", "patch roulette", "custom gradle task".
argument-hint: "[task-name]"
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Weaver Internals

Weaver (`io.canvasmc.weaver.patcher` v2.4.5) is a Paperweight fork. Understanding
its task flow is essential for debugging patch application and writing custom tasks.

## Task Flow (applyAllPatches)

```
1. checkoutRepoFromUpstream("paper")
   → copies Paper from Gradle cache, adds "upstream" remote, fetches, resets to upstream/main

2. runCanvasSetup
   → Paper source (commit = paperCommit)
   → Paper ATs (paperApi.at + paperServer.at, ~673 lines)
   → Paper patches (927 patches via Paperweight)
   → Canvas library imports
   → Canvas ATs (canvas.at, 87 lines)
   → Result: POST-AT cache repo at canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/

3. applyMinecraftBasePatches
   → clones runCanvasSetup cache (POST-AT state)
   → git clean -fxd, git reset --hard HEAD
   → git am --3way 0001-*.patch ... 00NN-*.patch (base patches, needs index lines)
   → Result: canvas-server/src/minecraft/java/ (base-patched)

4. applyMinecraftSourcePatches
   → applies per-file patches with `patch` (NOT git am) because gitFilePatches=false
   → failed patches → canvas-server/minecraft-patches/rejected/
   → Result: canvas-server/src/minecraft/java/ (fully patched)

5. applyMinecraftFeaturePatches
   → applies feature patches as git commits
   → optional (features can be dropped)
```

## Patch Mechanism Types

| Type | Method | Use |
|------|--------|-----|
| `patchFile` | unified diff on single file | `build.gradle.kts` → `canvas-server/build.gradle.kts` |
| `patchRepo` | `git am` series on a repo | `paper-api`, `paper-server` source |
| `patchDir` | copy dir + apply file patches, with excludes | `paperApi` (excludes `build.gradle.kts`) |

## Key Config (build.gradle.kts)

```kotlin
paperweight {
    filterPatches = false       // RebuildGitPatches keeps empty patches
    gitFilePatches = false      // source patches use `patch`, not `git am`
    upstreams.paper { ... }
}
```

`filterPatches = false` is important — it means `RebuildGitPatches` and
`RebuildBaseGitPatches` tasks have `filterPatches = false`, so empty patches
are retained (don't delete them thinking they're unused).

## Task Cache Location

```
canvas-server/.gradle/caches/paperweight/taskCache/
└── runCanvasSetup/          ← POST-AT cache repo (base patches clone from here)
```

This is the **POST-AT state** — Paper source with Canvas ATs applied but no
Canvas patches yet. Base patches are generated from and applied to this state.

## Rebuild Tasks

| Task | What it does |
|------|--------------|
| `rebuildMinecraftSourcePatches` | Regenerate per-file source `.patch` files from `src/minecraft/java/` |
| `rebuildMinecraftBasePatches` | Regenerate base `.patch` files from git commits |
| `rebuildPaperApiFilePatches` | Regenerate `canvas-api/build.gradle.kts.patch` |
| `rebuildPaperServerFilePatches` | Regenerate `canvas-server/build.gradle.kts.patch` |
| `rebuildFoliaSingleFilePatches` | Legacy name — rebuilds both build.gradle.kts patches |
| `fixupMinecraftSourcePatches` | Normalize source before rebuild (import ordering, etc.) |

`rbp.sh` auto-detects which dirs changed and runs only the needed fixup + rebuild tasks.

## Patch Roulette

Canvas integrates with a Patch Roulette service for collaborative patch review:
```kotlin
tasks.withType<AbstractPatchRouletteTask>().configureEach {
    endpoint = "https://patch-roulette.canvasmc.io/api"
}
```
Tasks: `canvasPatchRoulettePush` (push patches for review). Used by `prepare_for_patch_roulette.sh`.

## Debugging Weaver

```bash
./gradlew applyMinecraftBasePatches -Dpaperweight.debug=true --no-configuration-cache
```

Inspect the cache repo directly:
```bash
ls canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
git log --oneline -5    # see POST-AT state commits
```

## Writing Custom Weaver Tasks

If you need a custom task (rare), follow the pattern in root `build.gradle.kts`:
```kotlin
tasks.register("fixupMinecraftFilePatches") {
    dependsOn(":canvas-server:fixupMinecraftSourcePatches")
}
```
Register at root, delegate to subproject tasks. Keep `--no-configuration-cache`
for tasks that modify the patch graph.

## Custom Task Templates

Beyond the trivial `tasks.register` pattern, custom Weaver tasks that touch
the patch graph need care.

### Template: a task that depends on the POST-AT cache

```kotlin
tasks.register("myCustomTask") {
    dependsOn(":canvas-server:applyMinecraftBasePatches")
    // Source is now in canvas-server/src/minecraft/java/
    doLast {
        // Inspect/transform the applied source
    }
}
```
- Always `dependsOn` the patch task that produces the source you need.
- Use `--no-configuration-cache` for tasks that modify the patch graph or
  read transient cache state.
- Register at root `build.gradle.kts`, delegate to subproject tasks.

### Template: a rebuild task that regenerates patches

Follow `rbp.sh`'s pattern — depend on the fixup task, then the rebuild task:
```kotlin
tasks.register("rebuildMyPatches") {
    dependsOn(":canvas-server:fixupMinecraftSourcePatches")
    dependsOn(":canvas-server:rebuildMinecraftSourcePatches")
}
```
- `fixup*` normalizes source (import ordering) before rebuild — always run it
  first or the rebuild produces noisy diffs.
- `filterPatches = false` means empty patches are retained; don't add logic
  that deletes them.

### Template: a task that reads the cache repo

```kotlin
tasks.register("inspectCache") {
    doLast {
        val cacheDir = file("canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/")
        // Read POST-AT state directly
    }
}
```
- The cache is a full git repo — you can `git log` it to inspect POST-AT
  commits.
- Don't write to the cache from a custom task; it invalidates downstream
  tasks. Read-only inspection only.

## Cache Debugging

The `runCanvasSetup` cache can become stale or corrupt, causing patch
application failures that don't reflect the actual patches.

### Symptoms of cache corruption

- Patches apply cleanly on a fresh clone but fail on your machine.
- `git am` fails with "patch does not apply" despite no source changes.
- `applyMinecraftBasePatches` fails with index/context mismatches.
- Stale AT state — access transformer changes aren't reflected.

### Diagnosing

```bash
# Inspect the cache repo
ls canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
git log --oneline -5    # POST-AT state commits
git status              # should be clean; dirty = corruption

# Compare cache HEAD vs expected paperCommit
git rev-parse HEAD
grep '^paperCommit=' ../../../../../../gradle.properties
```

### Force cache reset

```bash
# Nuclear option — delete the entire paperweight cache
rm -rf canvas-server/.gradle/caches/paperweight/
./gradlew applyAllPatches --no-configuration-cache
```
- This forces `runCanvasSetup` to rebuild from scratch (re-applies Paper
  patches + Canvas ATs).
- Slow but reliable — use when incremental cache state is suspect.
- After reset, the next `applyAllPatches` rebuilds the POST-AT cache.

### Partial reset

If only ATs changed but the cache is stale:
```bash
rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
./gradlew runCanvasSetup --no-configuration-cache
./gradlew applyMinecraftBasePatches --no-configuration-cache
```

### Prevention

- Run `./gradlew applyAllPatches --no-configuration-cache` after AT changes.
- Don't manually edit files under `.gradle/caches/`.
- If switching branches with different ATs, reset the cache.

## folia.at in Weaver

Canvas may ship a `folia.at` access-transformer file alongside `canvas.at`.
Weaver's AT handling applies all configured AT files during `runCanvasSetup`.

### How Weaver handles multiple AT files

- `runCanvasSetup` applies Paper ATs (`paperApi.at`, `paperServer.at`) first,
  then Canvas ATs (`canvas.at`, and `folia.at` if present).
- The combined AT set produces the POST-AT cache state.
- AT file order matters if two files widen the same field — later files win.
  Grep `build.gradle.kts` for the AT file list/order:
  ```bash
  grep -rn "\.at\b\|accessTransformer\|atFiles" build.gradle.kts canvas-server/build.gradle.kts
  ```

### When folia.at changes

- Any `folia.at` edit invalidates the `runCanvasSetup` cache (AT state
  changes) — reset the cache (see Cache Debugging) or run with
  `--no-configuration-cache`.
- Verify the AT applied by grepping the applied source for widened access
  (`public` / `public-f` on previously package-private fields).
- `build-data/canvas.at` (87 lines) is the primary Canvas AT; `folia.at` (if
  present) carries Folia-origin ATs absorbed into Canvas.

### Debugging AT application

```bash
# List all AT files Weaver applies
grep -rn "at\b\|accessTransform" build.gradle.kts canvas-server/build.gradle.kts

# Verify a specific AT line applied
grep -rn "public.*targetField" canvas-server/src/minecraft/java/
```
If an AT line didn't apply, the field/method may not exist at the current
`paperCommit` (renamed/removed upstream), or the AT syntax is wrong (see
`/canvas-at-guard`).

## Pitfalls

1. **`gitFilePatches = false`** — source patches use `patch`, so no `index` lines needed, but context must match exactly.
2. **`applyUpstreamNested.set(false)`** — Paper's nested patches are not re-applied; Canvas patches directly on Paper output.
3. **Cache invalidation** — if `runCanvasSetup` cache is stale, delete `canvas-server/.gradle/caches/paperweight/` and re-run.
4. **`filterPatches = false`** — empty patches are intentional (placeholders), don't remove them.
