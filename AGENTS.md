# Canvas — Agent Guide

Canvas is a high-performance fork of **Paper** (dev/26.2) with **region threading**
absorbed from Folia as Canvas-original base patches. No Folia dependency.
Build chain: `CraftBukkit → Spigot → Paper → Canvas`.

## Critical Facts (verify before assuming — these change)

- **Paper commit**: see `gradle.properties` → `paperCommit` (currently `a1e989c…`, dev/26.2)
- **Java**: 25 (toolchain + `options.release = 25`)
- **Gradle**: 9.5.1, configuration-cache + build-cache + parallel enabled
- **Patcher**: `io.canvasmc.weaver.patcher` v2.4.5 (Paperweight fork)
- **MC version**: 26.2 (`mcVersion` / `apiVersion`)
- **Branch**: `ver/paper-base` (migration in progress — see `roadmap.md`)

**Always read `gradle.properties` and `roadmap.md` before acting — values drift.**

## Patch Layout (3 layers, 3 locations)

| Layer | Location | Apply via | Count |
|-------|----------|-----------|-------|
| Base patches | `canvas-server/minecraft-patches/base/` | `git am --3way` (needs `index` lines) | 14 |
| Source patches | `canvas-server/minecraft-patches/sources/` | `patch` (per-file, `gitFilePatches=false`) | 142 |
| Feature patches | `canvas-server/minecraft-patches/features/` | git commits, optional | 2 |
| API base | `canvas-api/paper-patches/base/` | git am | 7 |
| Server base | `canvas-server/paper-patches/base/` | git am | 9 |

Access Transformers: `build-data/canvas.at` (87 lines), `build-data/paperApi.at`, `build-data/paperServer.at`.

## Build Commands

```bash
./gradlew applyAllPatches          # Apply all patches → construct source
./gradlew createPaperclipJar       # Build paperclip jar
./gradlew runDev                   # Start dev server (loads *-plugin / *-debug dirs)
./gradlew test                     # Run unit tests
./upstream.sh update|apply|rebuild|full   # Paper upstream sync
./rbp.sh [--force] [--gradle]      # Rebuild patches (auto-detects changes)
```

## Region Threading — Non-Negotiable Rules

1. **Only the tick thread of a region may access that region's data.** Violations → `IllegalStateException`.
2. Use the correct scheduler: `RegionScheduler` (by location), `EntityScheduler` (follows entity), `GlobalRegionScheduler` (global tick), `AsyncScheduler` (off-tick).
3. Never access entity/world/block data from async without scheduling.
4. `TickThread.isTickThreadFor(...)` / `ensureTickThread(...)` validate ownership.
5. Canvas's own scheduler is **AFFINITY** (`io.canvasmc.canvas.tick.*`) — not Folia's.

## AI Policy (policies/AI_POLICY.md)

- No fully AI-generated PRs. AI is an **assistive tool**, not a replacement.
- Review everything the AI produces before submitting.
- Follow surrounding code style — no sharp style changes in patches.
- Test changes locally before PRing.

## Agent Workflow (Plan → Execute → Verify)

1. **Ground**: read actual current source/patches — MC 26.2 APIs change, never guess from training data.
2. **Plan**: minimal diff, respect patch layer boundaries.
3. **Execute**: edit in the correct patch layer / source dir.
4. **Verify**: `./gradlew applyAllPatches` → compile → `./gradlew test` → `runDev` if runtime.
5. **Rebuild**: `./rbp.sh` to regenerate patch files after source edits.

## Skills (20 — future-proof for dual upstream + churn)

Skills live in `.devin/skills/`. Invoke with `/canvas-<name>` (or agent auto-picks).
Grounded in DeepWiki (CraftCanvasMC/Canvas, PaperMC/Paper) + local source + Devin skill format.

Core navigation & research:
- `/canvas-architecture-map` (subagent — exploration-heavy)
- `/canvas-doc-research` (subagent — DeepWiki MCP + local source, merged deepwiki-usage)

Upstream & patches (the heart of seamless dual upstream):
- `/canvas-upstream-sync` (Paper direct + Canvas OG, merged dual-upstream)
- `/canvas-patch-lifecycle` (POST-AT cycle, Weaver task flow)
- `/canvas-patch-authoring` (marking convention, minimal hunks)
- `/canvas-at-guard` (AT syntax, POST-AT dependency, merged access-transformers)

Refactor & future-proofing:
- `/canvas-refactor-patterns` (minimal diff, layer respect, merged refactor-guard)
- `/canvas-architecture-evolution` (ADR pattern, migrations, breaking changes)
- `/canvas-verify-build` (subagent — apply → compile → test → rbp → runDev)

Build, Weaver, threading:
- `/canvas-build-system` (Weaver, Java 25, Gradle 9.5.1)
- `/canvas-weaver-internals` (task flow, patchFile/patchRepo/patchDir)
- `/canvas-region-threading` (CRS/AFFINITY, TickGuard, scheduler selection)
- `/canvas-affinity-scheduler` (subagent — EDF, task pinning, work stealing)
- `/canvas-chunk-system` (subagent — BalancedChunkSystem, ThreadedRegionizer)
- `/canvas-debug-threading` (subagent — IllegalStateException, watchdog, races)
- `/canvas-region-profiling` (task pinning, Spark, per-region timing)

Config, plugins, review, workflow:
- `/canvas-config-system` (per-world, global.yml, 96+ files)
- `/canvas-plugin-compat` (folia-supported, paper-plugin.yml, scheduler migration)
- `/canvas-code-review` (subagent — threading safety, patch layers, AI policy)
- `/canvas-pr-workflow` (user-only triggers — PR, release, CI/CD)

See individual SKILL.md for triggers and exact usage. All skills are written for
frequent Paper + Canvas OG upstreams + our own architecture changes.
