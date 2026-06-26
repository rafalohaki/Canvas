---
name: canvas-architecture-map
description: Use whenever needing to navigate the Canvas codebase — where things live, how layers connect, what each directory contains, how patches map to source, or orienting before a task. The navigational entry point for the project. Triggers on "where is", "how is Canvas structured", "codebase map", "architecture", "where does X live", "orient me", "navigate", "project structure", "what's in".
triggers:
  - user
  - model
subagent: true
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Architecture Map

Navigational map of the Canvas codebase. **Read this first** when orienting on a
task. This skill is exploration-heavy — runs as a subagent to keep the parent
context clean.

## Source of Truth (read before assuming — values drift)

- `gradle.properties` → `paperCommit` (Paper dev/26.2 pin), `mcVersion`, `apiVersion`
- `roadmap.md` → dual upstream status (Paper + Canvas OG), current migration phase
- `AGENTS.md` → patch layout table, critical facts, AI policy

## High-Level Structure (Dual Upstream View)

```
Canvas/
├── build.gradle.kts
├── gradle.properties         # paperCommit (Paper pin) — add canvasCommit for OG
├── roadmap.md                # Dual upstream status (Paper + Canvas OG)
├── AGENTS.md
│
├── build-data/
│   ├── canvas.at             # Our ATs (applied in runCanvasSetup before base patches)
│   ├── folia.at              # Folia-originated ATs (absorbed from upstream Canvas)
│   ├── paperApi.at
│   └── paperServer.at
│
├── canvas-api/paper-patches/base/{canvas,local}/   # 7 API base patches
├── canvas-server/
│   ├── paper-patches/base/{canvas,local}/ + files/  # 9 server base patches
│   ├── minecraft-patches/
│   │   ├── base/{canvas,local}/      # 14 base patches (git am --3way)
│   │   ├── sources/{canvas,local}/   # 142 per-file source patches (ca/ io/ net/)
│   │   ├── features/                 # 2 feature patches (git commits)
│   │   └── rejected/                 # failed source patches land here
│   └── src/minecraft/java/           # final applied source (after applyAllPatches)
│
├── scripts/
│   └── apatch.sh             # Apply single patch with wiggle fallback
│
├── upstream.sh               # Paper upstream sync (update/apply/rebuild/full)
├── rbp.sh                    # Rebuild patches (auto-detect changes)
├── pre_update.sh             # Pre-patch-roulette: enable git file patches
├── prepare_for_patch_roulette.sh  # Post-roulette: move patches back, push
└── .devin/skills/            # project skills (this one + others)
```

## Dual Upstream Partitioning (canvas/ vs local/)

Every patch layer is split into `canvas/` and `local/` subdirs:
- `canvas/` = patches absorbed from CraftCanvasMC/Canvas OG (our parent fork)
- `local/`  = our delta / fixes / opinions on top

This keeps upstream sync seamless: OG changes map to `canvas/`, our work stays
in `local/`. See `/canvas-upstream-sync` for the full strategy.

## Layer Model

```
CraftBukkit → Spigot → Paper (dev/26.2, commit = paperCommit)
                          ↓ Canvas patches on top
                       Canvas API (canvas-api)  +  Canvas Server (canvas-server)
                          ↑ Canvas OG patches (CraftCanvasMC/Canvas) absorbed
```

Canvas does **not** depend on Folia. Folia's region threading patches were
absorbed as Canvas-original base patches (no Folia jar/git dependency).

## CRS Scheduler (Canvas Region-Specific)

Canvas's own scheduler, replacing Folia's. EDF-based (Earliest Deadline First)
with task pinning and work stealing.

- Package: `io.canvasmc.canvas.tick.*`
- Location (applied): `canvas-server/src/minecraft/java/io/canvasmc/canvas/tick/`
- Confirm: `grep -rl "io.canvasmc.canvas.tick" canvas-server/src/minecraft/java/`
- Related: `io.papermc.paper.threadedregions.*` (region threading runtime,
  Folia-origin, now Canvas-maintained)

Do NOT confuse with Folia's scheduler — Canvas rewrote the scheduling layer.
See `/canvas-affinity-scheduler` for details.

## Patch → Source Mapping

```
canvas-server/minecraft-patches/base/{canvas,local}/0001-*.patch   ─┐
canvas-server/minecraft-patches/base/{canvas,local}/0002-*.patch   ─┤ git am --3way
...                                                                 ─┤ (POST-AT state)
canvas-server/minecraft-patches/base/{canvas,local}/0014-*.patch   ─┘
                          ↓
canvas-server/minecraft-patches/sources/{canvas,local}/**/*.patch  ─┐ patch (per-file)
...                                                                 ─┤ (142 patches)
                          ↓
canvas-server/minecraft-patches/features/*.patch                    ─┐ git commits (optional)
                          ↓
canvas-server/src/minecraft/java/  ← final applied source
```

## Key Packages (grep to confirm — they shift)

| Package | What | Find it |
|---------|------|---------|
| `io.canvasmc.canvas.tick.*` | CRS scheduler (EDF, pinning, work stealing) | `grep -rl "io.canvasmc.canvas.tick" canvas-server/src/minecraft/java/` |
| `io.canvasmc.weaver.patcher` | Weaver plugin (Gradle plugin, not in source) | `build.gradle.kts` |
| `io.canvasmc.canvas.*` | Canvas core (config, region data, etc.) | `grep -rl "io.canvasmc.canvas" canvas-server/src/minecraft/java/` |
| `io.papermc.paper.threadedregions.*` | Region threading runtime (Folia-origin, now Canvas) | `grep -rl "threadedregions" canvas-server/src/minecraft/java/` |

## Key Base Patches (what they do)

| # | Patch | Origin | Core purpose |
|---|-------|--------|-------------|
| 0001 | Region-Threading-Base | Folia | Heart: ThreadedRegionizer, TickThread, schedulers |
| 0002 | Max-pending-logins | Folia | Login throttling |
| 0003 | Add-chunk-system-throughput-counters | Folia | Chunk throughput metrics |
| 0004 | Prevent-block-updates-non-loaded | Folia | Block update safety |
| 0005 | Block-reading-world-TE-worldgen | Folia | TE worldgen safety |
| 0006 | Sync-vehicle-position-disconnect | Folia | Vehicle position on disconnect |
| 0007 | Add-watchdog-thread | Folia | Region tick hang detection |
| 0008 | Remove-Vanilla-Profiler | Canvas | Remove incompatible profiler |
| 0009 | Remove-Dead-Old-Watchdog | Canvas | Clean up old watchdog |
| 0010 | Per-world-Canvas-configs | Canvas | Per-world config system |
| 0011 | Fixup-Region-Threading | Canvas | AbstractCommandExecution replacement |
| 0012 | Canvas-RegionizedWorldData | Canvas | Regionized world data |
| 0013 | Replace-Moonrise-Executor | Canvas | Canvas chunk executor |
| 0014 | Purpur-Ender-Chest | Canvas | 6-row ender chest config |

## Orientation Workflow

Before any task:
1. **Read `roadmap.md`** — is the migration still in progress? Current phase?
2. **Read `gradle.properties`** — current `paperCommit` / `mcVersion`?
3. **Grep for the target** — `grep -rl "Target" canvas-server/src/minecraft/java/` (if applied) or `canvas-server/minecraft-patches/` (if not)
4. **Identify the patch layer** — base / source / feature / AT
5. **Invoke the relevant skill** — `/canvas-patch-lifecycle`, `/canvas-region-threading`, `/canvas-affinity-scheduler`, etc.

## Quick Reference Commands

```bash
# Apply all patches (construct source)
./gradlew applyAllPatches --no-configuration-cache

# Find where something lives
grep -rl "ClassName" canvas-server/src/minecraft/java/ canvas-api/ 2>/dev/null

# See patch counts (current: 14 base, 142 sources, 2 features, 9 paper-server, 7 paper-api)
find canvas-server/minecraft-patches/base -name "*.patch" | wc -l
find canvas-server/minecraft-patches/sources -name "*.patch" | wc -l
find canvas-server/minecraft-patches/features -name "*.patch" | wc -l
find canvas-server/paper-patches/base -name "*.patch" | wc -l
find canvas-api/paper-patches/base -name "*.patch" | wc -l

# Check migration status
grep -A 5 "Phase 3b" roadmap.md

# Verify build
./gradlew :canvas-server:compileJava && echo "OK"
```

## When Architecture Changes

This map is a snapshot. Canvas is actively migrating (Folia→Paper absorbed).
When the architecture changes:

### Patches added
1. Update the patch count in the structure map above (base/sources/features).
2. Update `AGENTS.md` patch layout table.
3. Update `roadmap.md` with the new patch and its purpose.
4. Add the patch to the "Key Base Patches" table if it's a base patch.
5. Grep to confirm package locations before citing them.

### Patches removed
1. Remove from the structure map and "Key Base Patches" table.
2. Renumber subsequent patches (base patches must be sequential).
3. Update `AGENTS.md` patch layout table.
4. Update `roadmap.md` — note the removal and rationale.
5. Check if any ATs became unnecessary (see `/canvas-at-guard` → AT Validation).

### Patches merged
1. Update the structure map with the new merged patch count.
2. Update the "Key Base Patches" table — remove old entries, add the merged one.
3. Renumber if the merge changes sequence positions.
4. Update `AGENTS.md` patch layout table.
5. Update `roadmap.md` with an ADR entry documenting the merge rationale.
6. Regenerate all base patches from POST-AT state (`git format-patch`).

### General
- Always grep to confirm package locations before citing them — they shift.
- Run `find canvas-server/minecraft-patches/base -name "*.patch" | wc -l` to
  verify counts match what's documented here.
