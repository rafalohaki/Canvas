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

## Migration Playbook (MC Version Migration)

Concrete steps for migrating Canvas to a new Minecraft version (e.g.,
26.2→26.3). This is the highest-risk operation — plan carefully.

### Phase 1: Assessment (before touching anything)
1. **Read upstream Paper's migration notes** — DeepWiki
   (`PaperMC/Paper`, "What changed in MC 26.3?") + Paper's CHANGES file.
2. **Check upstream Canvas** — has CraftCanvasMC/Canvas started the migration?
   `git fetch upstream && git log upstream/main --oneline -20`
3. **Assess API breakage** — grep for MC-version-sensitive APIs:
   ```bash
   grep -rn "26\.2\|1\.21" canvas-api/ canvas-server/minecraft-patches/
   grep -rn "mcVersion\|apiVersion" gradle.properties
   ```
4. **Estimate effort** — count patches likely affected:
   ```bash
   # Patches touching files that changed in the new version
   grep -rl "<changed-files>" canvas-server/minecraft-patches/
   ```

### Phase 2: Preparation
1. Create a migration branch: `git checkout -b ver/26.3-migration`
2. Bump `mcVersion` and `apiVersion` in `gradle.properties`.
3. Update `paperCommit` to the Paper commit for the new MC version.
4. Run `./gradlew applyAllPatches --no-configuration-cache` — expect rejects.
5. Document the initial reject count in `roadmap.md`.

### Phase 3: Patch Roulette (fix rejects)
1. Run `./pre_update.sh` to enable git file patches and move source patches.
2. For each rejected base patch:
   - `git am --abort`, `git apply --rej <patch>`, fix `.rej` files.
   - Regenerate with `git format-patch` from POST-AT state.
3. For each rejected source patch:
   - Fix hunk context/line numbers in `canvas-server/minecraft-patches/rejected/`.
   - Move back to `sources/` and re-apply.
4. Run `./prepare_for_patch_roulette.sh` when done.

### Phase 4: AT Updates
1. Check if upstream Paper changed visibility of AT'd members:
   ```bash
   grep -f build-data/canvas.at canvas-server/src/minecraft/java/ -rn
   ```
2. Remove ATs that are now public in upstream (see `/canvas-at-guard` → AT Validation).
3. Add new ATs for members that became private in the new version.
4. Clean cache + re-apply after AT changes.

### Phase 5: Verification
1. `./gradlew applyAllPatches --no-configuration-cache` — zero rejects.
2. `./gradlew :canvas-api:compileJava :canvas-server:compileJava` — compiles.
3. `./gradlew test` — all tests pass (investigate every failure).
4. `./gradlew runDev` — server starts, basic functionality works.
5. `./rbp.sh` — patches regenerate cleanly.
6. `./gradlew createPaperclipJar` — distributable jar builds.

### Phase 6: Documentation
1. Update `roadmap.md` with a migration ADR.
2. Update `AGENTS.md` — new `mcVersion`, `paperCommit`, patch counts.
3. Update `/canvas-architecture-map` — structure, counts, key patches.
4. Update all affected skills.

## Deprecation Timeline

How to phase out old APIs safely without breaking plugins:

### Stage 1: Deprecation announcement
- Add `@Deprecated(forRemoval = true, since = "<version>")` to the API.
- Add `@Deprecated` in the patch with a `// Canvas start - deprecate` marker.
- Document in `roadmap.md` — note the replacement API and target removal version.
- Log a warning when the deprecated API is called:
  ```java
  // Canvas start - deprecation warning
  if (CanvasConfig.deprecationWarnings) {
      LOGGER.warn("Deprecated API called: {} — use {} instead", methodName, replacement);
  }
  // Canvas end - deprecation warning
  ```

### Stage 2: Grace period (1-2 MC versions)
- Keep the deprecated API functional.
- Monitor usage via the warning logs.
- Update `/canvas-plugin-compat` with migration guidance for plugin devs.

### Stage 3: Removal
- Remove the deprecated API in a dedicated base patch.
- Update all internal callers to the replacement.
- Document the removal in `roadmap.md` as a breaking change ADR.
- Bump `apiVersion` if the API was in the public surface.
- Test with `runDev` — load test plugins that may use the old API.

### Timeline guidelines
- Minor API changes: deprecate in N, remove in N+1.
- Major API changes: deprecate in N, remove in N+2 (one full MC cycle).
- Never remove without a deprecation cycle — plugins break silently.

## Cross-References

- `/canvas-refactor-patterns` — safe refactoring patterns, impact assessment
- `/canvas-architecture-map` — codebase navigation, patch inventory
- `/canvas-at-guard` — AT changes that affect architecture
- `/canvas-upstream-sync` — absorbing upstream changes
- `/canvas-patch-authoring` — base patch creation and splitting
- `/canvas-region-threading` — threading rules (non-negotiable)
- `/canvas-affinity-scheduler` — CRS scheduler internals
- `/canvas-chunk-system` — chunk system architecture
- `/canvas-migration-patterns` — concrete migration patterns (Folia→Paper, patch merging, AT migration)

Sources: DeepWiki (Canvas CRS scheduler — EDF, task pinning, work stealing;
Weaver task flow — AT application order, base patch mechanism), `roadmap.md`
(Folia→Paper migration log, POST-AT discovery), `AGENTS.md` (patch layout,
region threading rules).
