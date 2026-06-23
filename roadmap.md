# Canvas Migration Roadmap: Folia-based → Paper-based

## Goal

Migrate Canvas from `CraftBukkit → Spigot → Paper → Folia → Canvas` to
`CraftBukkit → Spigot → Paper → Canvas`.

Canvas absorbs Folia's region threading patches as its own base patches.
No dependency on any Folia repository. Upstream directly from PaperMC/Paper.

## Key Facts (verified)

- Canvas upstream: `CraftCanvasMC/Folia` @ `f1f501b8` (dev/26.2.x branch)
- CraftCanvasMC/Folia's Paper ref: `76d2ac758cb3abe75aceefa88207443768f585c6` (= PaperMC/Paper HEAD)
- CraftCanvasMC/Folia has 17 patches (profiler already removed by Canvas fork)
- Canvas uses Weaver (`io.canvasmc.weaver.patcher` v2.4.5) — fork of Paperweight with `base` patches
- Canvas `canvas-api/folia-patches/` and `canvas-server/folia-patches/` are EMPTY
- `feat/rewrite-autosave` branch: 28 commits ahead of master, clean fast-forward

## Folia Patches to Absorb (from CraftCanvasMC/Folia @ f1f501b8)

### folia-api/paper-patches/features/ → canvas-api/paper-patches/base/ (4 patches)

| New # | File | Lines | Action |
|-------|------|-------|--------|
| 0001 | Force-disable-timings.patch | 19 | KEEP |
| 0002 | Region-scheduler-API.patch | 44 | KEEP |
| 0003 | Require-plugins-Folia-sup.patch | 80 | KEEP |
| 0004 | Add-TPS-From-Region.patch | 92 | KEEP |

### folia-server/paper-patches/features/ → canvas-server/paper-patches/base/ (6 patches, 4 KEEP)

| New # | File | Lines | Action |
|-------|------|-------|--------|
| 0001 | Region-Threading-Base.patch | 4147 | KEEP |
| — | Update-Logo.patch | 1037 | DROP (Canvas has own rebrand) |
| — | Build-changes.patch | 91 | DROP (Canvas has own build changes) |
| 0002 | Fix-tests-by-removing-them.patch | 19 | KEEP |
| 0003 | Add-watchdog-thread.patch | 21 | KEEP |
| 0004 | Add-TPS-From-Region.patch | 80 | KEEP |

### folia-server/minecraft-patches/features/ → canvas-server/minecraft-patches/base/ (7 patches)

| New # | File | Lines | Action |
|-------|------|-------|--------|
| 0001 | Region-Threading-Base.patch | 20203 | KEEP (heart of Folia) |
| 0002 | Max-pending-logins.patch | 42 | KEEP |
| 0003 | Add-chunk-system-throughput-counters.patch | 86 | KEEP |
| 0004 | Prevent-block-updates-non-loaded.patch | 135 | KEEP |
| 0005 | Block-reading-world-TE-worldgen.patch | 24 | KEEP |
| 0006 | Sync-vehicle-position-disconnect.patch | 32 | KEEP |
| 0007 | Add-watchdog-thread.patch | 185 | KEEP |

### Total: 15 patches to absorb

## Canvas Existing Patches (renumber after Folia absorption)

### canvas-api/paper-patches/base/ (current → new)

| Current | New | File |
|---------|-----|------|
| 0001-Rebrand | 0005-Rebrand | |
| 0002-Purpur-Ender-Chest | 0006-Purpur-Ender-Chest | |
| 0003-Add-canvas-supported | 0007-Add-canvas-supported | |

### canvas-server/paper-patches/base/ (current → new)

| Current | New | File |
|---------|-----|------|
| 0001-Rebrand | 0005-Rebrand | |
| 0002-Fixup-Region-Threading | 0006-Fixup-Region-Threading | |
| 0003-Replace-Moonrise-Executor | 0007-Replace-Moonrise-Executor | |
| 0004-Add-canvas-supported | 0008-Add-canvas-supported | |
| 0005-Purpur-Ender-Chest | 0009-Purpur-Ender-Chest | |

### canvas-server/minecraft-patches/base/ (current → new)

| Current | New | File |
|---------|-----|------|
| 0001-Remove-Vanilla-Profiler | 0008-Remove-Vanilla-Profiler | |
| 0002-Remove-Dead-Old-Watchdog | 0009-Remove-Dead-Old-Watchdog | |
| 0003-Per-world-Canvas-configs | 0010-Per-world-Canvas-configs | |
| 0004-Fixup-Region-Threading | 0011-Fixup-Region-Threading | |
| 0005-Canvas-RegionizedWorldData | 0012-Canvas-RegionizedWorldData | |
| 0006-Replace-Moonrise-Executor | 0013-Replace-Moonrise-Executor | |
| 0007-Purpur-Ender-Chest | 0014-Purpur-Ender-Chest | |

## Phases

### Phase 0: Branch setup + autosave merge
- [x] Create branch `ver/paper-base` on rafalohaki/Canvas
- [x] Merge `upstream/feat/rewrite-autosave` (28 commits, autosave fixes)

### Phase 1: Absorb Folia patches
- [x] Copy 15 Folia patches into Canvas base dirs with new numbering
- [x] Renumber Canvas existing base patches
- [x] Update patch headers (Folia → Canvas - absorbed from Folia)

### Phase 2: Rebuild build system
- [x] Rewrite root `build.gradle.kts` — `upstreams.register("paper")`
- [x] Rewrite `canvas-server/build.gradle.kts.patch` — patch on `paper-server`
- [x] Rewrite `canvas-api/build.gradle.kts.patch` — patch on `paper-api`
- [x] Update `gradle.properties` — `paperCommit` instead of `foliaCommit`
- [x] Remove `canvas-*-patches/folia-patches/` dirs

### Phase 3: Test and fix
- [ ] Run `./gradlew applyAllPatches` — fix conflicts
- [ ] Run `./gradlew createPaperclipJar` — build test
- [ ] Run `./gradlew runDev` — runtime test

### Phase 4: Scripts and CI
- [ ] Add `upstream.sh` — Paper upstream update script
- [ ] Add `.github/workflows/upstream-check.yml` — weekly Paper update checker
- [ ] Add `.github/workflows/build.yml` — build CI
- [ ] Update `pre_update.sh`, `rbp.sh`, `prepare_for_patch_roulette.sh`

### Phase 5: Polish
- [ ] Update `README.md` — "fork of Paper with region threading"
- [ ] Update `policies/CONTRIBUTING.md`
- [ ] Remove `canvas-server/PROFILER_REMOVAL_README.MD` (obsolete)
- [ ] Cleanup Folia references in scripts

### Phase 6: Verification
- [ ] Test upstream update (bump paperCommit, apply, fix)
- [ ] Verify Canvas upstreamability (fork can upstream Canvas)
- [ ] Full build + runDev test

## What Does NOT Change

- AFFINITY scheduler (`io.canvasmc.canvas.tick.*`)
- Region profiler (Canvas own, not Folia)
- Chunk system rewrite (`BalancedChunkSystem`)
- Config system (96+ files)
- All 142 source patches (context matches because Folia base patches apply first)
- All 122 new Canvas files
- Plugin compat (still Folia-level, `folia-supported: true`)
- Weaver (`io.canvasmc.weaver.patcher`)
