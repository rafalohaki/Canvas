# Canvas Migration Roadmap: Folia-based → Paper-based

## Goal

Migrate Canvas from `CraftBukkit → Spigot → Paper → Folia → Canvas` to
`CraftBukkit → Spigot → Paper → Canvas`.

Canvas absorbs Folia's region threading patches as its own base patches.
No dependency on any Folia repository. Upstream directly from PaperMC/Paper.

## Key Facts (verified)

- Paper commit (dev/26.2): `a1e989c03643f812772d2213b087d34f6d917d49`
- Canvas uses Weaver (`io.canvasmc.weaver.patcher` v2.4.5) — fork of Paperweight with `base` patches
- 14 base patches: 7 Folia-absorbed (0001-0007) + 7 Canvas-original (0008-0014)
- 142 source patches in `canvas-server/minecraft-patches/sources/` — 9 hunks need fixing
- `build-data/canvas.at`: 87 lines, 85 Canvas-specific AT declarations
- Branch: `ver/paper-base`
- Java 25, Gradle 9.5.1

## Critical Discoveries

### 1. Canvas ATs HELP, not hinder, Folia patches
- `build-data/canvas.at` changes `private` → `public` on 43 files (e.g., `Entity.position`, `Entity.dimensions`)
- Folia patches were written against Folia's own AT-applied state (same `private` → `public` changes)
- When Canvas ATs are applied FIRST (via `runCanvasSetup`), the source files match what Folia patches expect
- Zero rejects when applying on POST-AT state vs 33 rejects on PRE-AT state

### 2. Weaver's `applyMinecraftBasePatches` uses `git am --3way`
- Base patches require `index` lines with valid blob SHA1 hashes
- Without `index` lines: `git am --3way` fails with "sha1 information is lacking or useless"
- Solution: regenerate patches using `git format-patch` from the POST-AT state (`runCanvasSetup` cache)

### 3. "Apply on POST-AT, generate patches, apply on POST-AT" cycle
1. Copy `runCanvasSetup` cache (POST-AT, commit `344eb69 canvas ATs`)
2. Apply original patches with `patch -p1 --fuzz=3`, fix rejects
3. Commit each patch individually
4. `git format-patch` generates patches with correct `index` lines (POST-AT blob hashes)
5. Weaver's `git am --3way` succeeds because blob hashes exist in the cloned repo

## Patch Layout

### canvas-api/paper-patches/base/ (7 patches)
| # | File | Origin |
|---|------|--------|
| 0001 | Force-disable-timings | Folia absorbed |
| 0002 | Region-scheduler-API | Folia absorbed |
| 0003 | Require-plugins-Folia-sup | Folia absorbed |
| 0004 | Add-TPS-From-Region | Folia absorbed |
| 0005 | Rebrand | Canvas original |
| 0006 | Purpur-Ender-Chest | Canvas original |
| 0007 | Add-canvas-supported | Canvas original |

### canvas-server/paper-patches/base/ (9 patches)
| # | File | Origin |
|---|------|--------|
| 0001 | Region-Threading-Base | Folia absorbed |
| 0002 | Fix-tests-by-removing-them | Folia absorbed |
| 0003 | Add-watchdog-thread | Folia absorbed |
| 0004 | Add-TPS-From-Region | Folia absorbed |
| 0005 | Rebrand | Canvas original |
| 0006 | Fixup-Region-Threading | Canvas original |
| 0007 | Replace-Moonrise-Executor | Canvas original |
| 0008 | Add-canvas-supported | Canvas original |
| 0009 | Purpur-Ender-Chest | Canvas original |

### canvas-server/minecraft-patches/base/ (14 patches)
| # | File | Origin |
|---|------|--------|
| 0001 | Region-Threading-Base | Folia absorbed (heart of Folia) |
| 0002 | Max-pending-logins | Folia absorbed |
| 0003 | Add-chunk-system-throughput-counters | Folia absorbed |
| 0004 | Prevent-block-updates-non-loaded | Folia absorbed |
| 0005 | Block-reading-world-TE-worldgen | Folia absorbed |
| 0006 | Sync-vehicle-position-disconnect | Folia absorbed |
| 0007 | Add-watchdog-thread | Folia absorbed |
| 0008 | Remove-Vanilla-Profiler | Canvas original |
| 0009 | Remove-Dead-Old-Watchdog | Canvas original |
| 0010 | Per-world-Canvas-configs | Canvas original |
| 0011 | Fixup-Region-Threading | Canvas original (replaces Folia command wrapping with `AbstractCommandExecution`) |
| 0012 | Canvas-RegionizedWorldData | Canvas original |
| 0013 | Replace-Moonrise-Executor | Canvas original |
| 0014 | Purpur-Ender-Chest | Canvas original |

### canvas-server/minecraft-patches/features/ (2 patches)
| # | File | Origin |
|---|------|--------|
| 0001 | Purpur-Alternative-Keepalive | Canvas original |
| 0002 | Disable-Criterion-Trigger-Config | Canvas original |

## Patch Application Flow

```
runCanvasSetup task:
  Paper source (commit a1e989c)
    → Paper ATs (673 lines)
    → Paper patches (927 patches)
    → Canvas library imports
    → Canvas ATs (87 lines, commit 344eb69 "canvas ATs")
    → canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/

applyMinecraftBasePatches task:
  clones runCanvasSetup cache (POST-AT state)
  git clean -fxd, git reset --hard HEAD
  git am --3way 0001-*.patch (14 patches with index lines)
  result: canvas-server/src/minecraft/java/

applyMinecraftSourcePatches task:
  applies 142 per-file patches on top of base-patched source
  uses patch (not git am) — gitFilePatches=false
  currently: 9/398 hunks fail

applyMinecraftFeaturePatches task:
  applies 2 feature patches
```

## Phases

### Phase 0: Branch setup + autosave merge ✅
- [x] Create branch `ver/paper-base` on rafalohaki/Canvas
- [x] Merge `upstream/feat/rewrite-autosave` (28 commits, autosave fixes)

### Phase 1: Absorb Folia patches ✅
- [x] Download 15 Folia patches from CraftCanvasMC/Folia `dev/26.2.x`
- [x] Copy into Canvas base dirs with new numbering
- [x] Renumber Canvas existing base patches (0005-0014)
- [x] Update patch headers
- [x] Strip `index` lines from Folia patches (blob hashes from Paper 26.1.2 don't exist in dev/26.2)

### Phase 2: Rebuild build system ✅
- [x] Rewrite root `build.gradle.kts` — `upstreams.register("paper")`
- [x] Rewrite `canvas-server/build.gradle.kts.patch` — patch on `paper-server`
- [x] Rewrite `canvas-api/build.gradle.kts.patch` — patch on `paper-api`
- [x] Update `gradle.properties` — `paperCommit` instead of `foliaCommit`
- [x] Remove `canvas-*-patches/folia-patches/` dirs
- [x] Remove ATs for `io.papermc.paper.threadedregions.*` (from Canvas base patches, not Minecraft)
- [x] Use `patchDir` instead of `patchRepo` for paperApi
- [x] `applyUpstreamNested.set(false)` — confirmed not needed
- [x] Clean up duplicate patches (0012/0013 duplicates removed)
- [x] Add Eclipse files to `.gitignore`
- [x] `./gradlew applyPaperApiBasePatches` — works (4 API patches)
- [x] `./gradlew applyPaperMinecraftBasePatches` — works (927 Paper patches)
- [x] `./gradlew runCanvasSetup` — works (creates POST-AT cache repo)

### Phase 3: Fix base patches ✅
- [x] Identified root cause: stripped `index` lines cause `git am --3way` failures
- [x] Discovered: Weaver uses `git am --3way` for base patches
- [x] Discovered: Canvas ATs help Folia patches apply (POST-AT state matches Folia expectations)
- [x] Regenerated all 14 base patches from POST-AT state (`runCanvasSetup` cache)
- [x] Fixed 54 rejected hunks in patch 0001 (33 files, Paper version differences)
- [x] Fixed 5 rejected hunks in patch 0011 (Canvas AbstractCommandExecution replacements)
- [x] `./gradlew applyMinecraftBasePatches` — PASSES (14 patches applied)

### Phase 3b: Fix source patches ✅
- [x] Fixed 9/398 failing hunks in 5 source patch files:
  - `RegionizedWorldData.java` (hunk 5)
  - `ServerChunkCache.java` (hunks 2-4)
  - `ServerPlayer.java` (hunks 3, 10)
  - `PlayerList.java` (hunks 0, 5)
  - `LevelChunk.java` (hunk 6)
- [x] `./gradlew applyAllPatches` — full pass (142 source patches + 14 base + 9 paper-server base all apply)

### Phase 4: Full build 🔴
- [ ] `./gradlew createPaperclipJar` — compile + build test
- [ ] `./gradlew runDev` — runtime test

### Phase 5: Scripts and CI
- [ ] Add `upstream.sh` — Paper upstream update script
- [ ] Add `.github/workflows/upstream-check.yml` — weekly Paper update checker
- [ ] Add `.github/workflows/build.yml` — build CI
- [ ] Update `pre_update.sh`, `rbp.sh`, `prepare_for_patch_roulette.sh`

### Phase 6: Polish
- [ ] Update `README.md` — "fork of Paper with region threading"
- [ ] Update `policies/CONTRIBUTING.md`
- [ ] Remove `canvas-server/PROFILER_REMOVAL_README.MD` (obsolete)
- [ ] Cleanup Folia references in scripts and docs

### Phase 7: Verification
- [ ] Test upstream update (bump paperCommit, apply, fix)
- [ ] Verify Canvas upstreamability (fork can upstream Canvas)
- [ ] Full build + runDev test

## What Does NOT Change

- AFFINITY scheduler (`io.canvasmc.canvas.tick.*`)
- Region profiler (Canvas own, not Folia)
- Chunk system rewrite (`BalancedChunkSystem`)
- Config system (96+ files)
- Plugin compat (still Folia-level, `folia-supported: true`)
- Weaver (`io.canvasmc.weaver.patcher`)

## Weaver Internals (from bytecode analysis)

- `ApplyBasePatches`: clones `runCanvasSetup` cache repo, `git clean -fxd`, `git reset --hard HEAD`, `git am --3way *.patch`
- `ApplyFilePatches`: applies per-file patches using `patch` (not `git am`) when `gitFilePatches=false`
- `checkoutRepoFromUpstream`: copies from Gradle cache, adds `upstream` remote, fetches, resets to `upstream/main`
- Rebase-based approach: patches are applied as git commits; `rebuildPatches` converts commits back to patch files
