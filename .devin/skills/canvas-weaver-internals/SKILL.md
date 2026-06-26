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

## Pitfalls

1. **`gitFilePatches = false`** — source patches use `patch`, so no `index` lines needed, but context must match exactly.
2. **`applyUpstreamNested.set(false)`** — Paper's nested patches are not re-applied; Canvas patches directly on Paper output.
3. **Cache invalidation** — if `runCanvasSetup` cache is stale, delete `canvas-server/.gradle/caches/paperweight/` and re-run.
4. **`filterPatches = false`** — empty patches are intentional (placeholders), don't remove them.
