---
name: canvas-architecture-evolution
description: Use when planning or executing architecture changes in Canvas — ADRs, migration strategy, evolving the scheduler/chunk-system/threading, splitting base patches, absorbing upstream architecture, versioning in roadmap.md, dependency graph analysis, or breaking change protocol. Triggers on "architecture change", "ADR", "migration", "evolve", "breaking change", "future proof", "architecture decision", "split base patch", "absorb upstream architecture".
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

# Canvas Architecture Evolution

Skills for planning and executing architecture changes that survive dual
upstreams (Paper + Canvas OG) and frequent rebases.

## ADR Pattern (Architecture Decision Record)

Canvas uses `roadmap.md` as the living ADR log. For every architecture
decision, add a section:

```markdown
## ADR-NNN: <Title> (<date>)

### Context
<Why this change is needed — what problem, what upstream pressure>

### Decision
<What we decided — concrete, not vague>

### Consequences
- What breaks: <list>
- What needs updating: <patches, ATs, AGENTS.md, skills>
- Migration path: <steps if incremental>

### Alternatives Considered
<What else was on the table and why rejected>

### References
- DeepWiki: <repo/page>
- Patches: <base/00xx-*.patch>
- Commits: <hashes>
```

Number ADRs sequentially. Keep old ADRs in place — they document why past
decisions were made, which matters when upstream changes force revisiting.

## Migration Strategy

### Template: Folia to Paper (current migration)

Canvas absorbed Folia's region threading patches as Canvas-original base
patches. This is the reference migration pattern:

1. **Identify the source** — Folia patches, Canvas OG patches, or our own.
2. **Strip `index` lines** from source patches (blob hashes from other
   upstreams don't exist in our POST-AT state).
3. **Apply on POST-AT state** — Canvas ATs replicate the source upstream's
   `private → public` changes, so patches apply cleanly on POST-AT.
4. **Regenerate with `git format-patch`** from POST-AT — creates correct
   `index` lines for `git am --3way`.
5. **Renumber** — insert absorbed patches before Canvas-original patches,
   renumber Canvas ones.
6. **Partition** — absorbed patches go in `canvas/` subdir, our deltas in
   `local/`.
7. **Update `roadmap.md`** with the migration status and ADR.
8. **Update `AGENTS.md`** patch layout table.

See `roadmap.md` for the full Folia→Paper migration log. Key discovery:
Canvas ATs HELP, not hinder — zero rejects on POST-AT vs 33 on PRE-AT.

### General Migration Steps

```
1. DeepWiki the source upstream → understand the architecture
2. Map source patches to our layers (base/source/feature)
3. Check AT coverage → do we need new ATs for visibility?
4. Apply on POST-AT → fix rejects → commit individually
5. git format-patch → correct index lines
6. Partition into canvas/ or local/
7. Renumber base patches
8. Update roadmap.md + AGENTS.md
9. Full verification pipeline
```

## Evolving Core Subsystems Safely

### Scheduler (CRS — Canvas Region Scheduler)

Canvas CRS is EDF-based with task pinning and work stealing
(DeepWiki: Canvas scheduler). When evolving:

- **EDF/FIFO switch** is config-driven (`global.yml` → `scheduler`). Add new
  algorithms as new options, don't replace existing.
- **Task pinning** — region profiling depends on pinning. Don't remove the
  pinning system without coordinating with `/canvas-region-profiling`.
- **Work stealing** — threads steal from other regions when idle. Changes
  here affect TickThread ownership rules. See `/canvas-region-threading`.
- **Patch location** — scheduler changes go in `base/local/` only.
- **AT impact** — scheduler code may need ATs for `MinecraftServer` fields.
  Check `build-data/canvas.at`.

### Chunk System

- Canvas has a custom chunk executor (`0013-Replace-Moonrise-Executor`).
- Changes to chunk loading/unloading affect region boundaries.
- `RegionizedPlayerChunkLoader` is AT-dependent — check `canvas.at` entries.
- Chunk system changes must not break `TickThread.isTickThreadFor(...)`.

### Threading / Region Model

- `ThreadedRegionizer` is the core — regions are dynamic, not fixed.
- `TickThread` ownership is non-negotiable (AGENTS.md rule 1).
- Any change to region boundaries or tick thread assignment is high-impact.
- Must update `/canvas-region-threading` and `/canvas-debug-threading` skills.

## When to Split Base Patches

Base patches should be self-contained — each applies independently. Split when:

- A base patch grows beyond one logical concern.
- A base patch touches multiple subsystems that could evolve independently.
- Upstream changes make one part of a patch fail while the rest applies.

### Splitting Procedure

```bash
# 1. Apply all patches to get clean source
./gradlew applyAllPatches --no-configuration-cache

# 2. Go to the POST-AT cache repo
cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/

# 3. Apply only the patch you want to split
git am --3way <path-to-patch-to-split>

# 4. Reset to before the patch, apply partially
git reset HEAD~1
git add -p   # stage only the first logical part
git commit -m "first concern"
git add -A
git commit -m "second concern"

# 5. Generate new patches
git format-patch -2 HEAD -o <output-dir>/

# 6. Renumber all subsequent base patches
# 7. Update AGENTS.md patch layout table
# 8. Full verification
```

## Absorbing New Upstream Architecture Changes

When Paper or Canvas OG introduces an architecture change:

1. **DeepWiki first** — `deepwiki_ask_question(repo="PaperMC/Paper",
   question="What architectural change was made in <area>?")` to understand
   the design before reading diffs.
2. **Assess impact** — which of our patches, ATs, and skills are affected?
   ```bash
   grep -rl "<changed-class>" canvas-server/minecraft-patches/
   grep "<changed-class>" build-data/canvas.at
   ```
3. **Decide: absorb or override** —
   - Absorb into `canvas/` if it's an improvement we want.
   - Override in `local/` if it conflicts with our architecture.
4. **One dedicated base patch** for the adaptation.
5. **Update ATs** if upstream changed visibility of members we AT'd.
6. **Update `roadmap.md`** with an ADR entry.
7. **Update affected skills** — architecture map, threading, scheduler, etc.
8. **Full verification pipeline.**

## Versioning Architecture Changes in roadmap.md

`roadmap.md` tracks:
- Current migration phase (Folia→Paper in progress).
- Patch layout and counts.
- Key discoveries (POST-AT, index lines, AT coverage).
- ADR entries for each architecture decision.

When making an architecture change:

```bash
# Read current state
cat roadmap.md

# Add ADR section (see ADR pattern above)
# Update patch counts if they changed
# Update phase status if migration progressed

# Update AGENTS.md patch layout table
# (base: 14 → 15, etc.)
```

## Dependency Graph Analysis

Before architecture changes, map dependencies:

```bash
# What depends on this class?
grep -rl "ClassName" canvas-server/src/minecraft/java/ canvas-api/

# What patches modify this file?
grep -rl "FileName" canvas-server/minecraft-patches/

# What ATs target this class or its members?
grep "ClassName" build-data/canvas.at build-data/paperServer.at build-data/paperApi.at

# Is this class used across layers (base + source)?
grep -rl "ClassName" canvas-server/minecraft-patches/base/
grep -rl "ClassName" canvas-server/minecraft-patches/sources/

# Check API surface exposure
grep -rl "ClassName" canvas-api/paper-patches/

# Check if Canvas OG has diverged
deepwiki_ask_question(repo="CraftCanvasMC/Canvas",
  question="How does Canvas OG implement <ClassName>? Any recent changes?")
```

Build a mental (or written) dependency graph:
```
TargetClass
├── ATs: canvas.at lines X, Y
├── Base patches: 0001, 0007, 0013
├── Source patches: 0042, 0089, 0123
├── API patches: none
├── Callers: ClassA, ClassB, ClassC
└── Skills affected: region-threading, affinity-scheduler
```

## Breaking Change Protocol

When a change breaks existing behavior or API:

1. **Document in `roadmap.md`** as an ADR with "Breaking" tag.
2. **Assess plugin compatibility** — see `/canvas-plugin-compat`. Check if
   plugins use the affected API:
   ```bash
   grep -rl "affectedMethod\|affectedClass" canvas-api/
   ```
3. **Provide migration path** — if possible, deprecate first, remove later.
   - Patch 1: add new API + deprecate old
   - Patch 2: (next release) remove old API
4. **Update `AGENTS.md`** if the change affects the critical facts or
   non-negotiable rules.
5. **Update affected skills** — any skill that references the changed
   behavior must be updated in the same PR.
6. **Test with `runDev`** — load test plugins that exercise the changed area.
7. **Full verification pipeline:**
   ```bash
   ./gradlew applyAllPatches --no-configuration-cache
   ./gradlew :canvas-server:compileJava
   ./gradlew :canvas-api:compileJava
   ./gradlew test
   ./gradlew runDev
   ./rbp.sh
   ```

## Cross-References

- `/canvas-refactor-patterns` — safe refactoring patterns, impact assessment
- `/canvas-architecture-map` — codebase navigation, patch inventory
- `/canvas-at-guard` — AT changes that affect architecture
- `/canvas-upstream-sync` — absorbing upstream changes
- `/canvas-patch-authoring` — base patch creation and splitting
- `/canvas-region-threading` — threading rules (non-negotiable)
- `/canvas-affinity-scheduler` — CRS scheduler internals
- `/canvas-chunk-system` — chunk system architecture

Sources: DeepWiki (Canvas CRS scheduler — EDF, task pinning, work stealing;
Weaver task flow — AT application order, base patch mechanism), `roadmap.md`
(Folia→Paper migration log, POST-AT discovery), `AGENTS.md` (patch layout,
region threading rules).
