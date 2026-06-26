---
name: canvas-patch-authoring
description: Author new patches or edit existing ones correctly for Canvas layers (base vs sources vs features, canvas/ vs local/). Follow minimal diff, rebase-safe, POST-AT, index lines, Paper marking conventions, fully-qualified imports, one concern per patch. Triggers on "add patch", "new base patch", "edit source patch", "create feature", "write a patch for", "how to patch", "marking convention", "Canvas start".
triggers:
  - user
  - model
argument-hint: "[layer] [description]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
  - write
---

# Canvas Patch Authoring

## Patch Layers (strict)

| Layer     | Dir                              | Method              | When to use                              | Rebase risk |
|-----------|----------------------------------|---------------------|------------------------------------------|-------------|
| base      | minecraft-patches/base/{canvas,local}/ | git am --3way      | Architecture, big replaces, new subsystems | medium      |
| source    | minecraft-patches/sources/{canvas,local}/ | patch (per-file) | Single file tweaks, bug fixes            | high        |
| feature   | minecraft-patches/features/      | git commits         | Optional add-ons (can be dropped)        | low         |
| paper-api | canvas-api/paper-patches/base/{canvas,local}/ | git am     | API additions/changes                    | medium      |
| paper-srv | canvas-server/paper-patches/...  | git am / files      | Non-MC server changes                    | medium      |

Never mix concerns in one patch. **One concern per patch.**

## Before Writing Any Patch

1. `read gradle.properties` + `roadmap.md`
2. Decide layer + subdir (`canvas/` vs `local/`)
3. Ground in current source: `applyAllPatches` first if needed.
4. Check for existing AT that could avoid a patch.

## Paper Marking Convention (Canvas variant)

Mark every change block so reviewers and rebases can find it. Paper uses
`// Paper start - <desc>` / `// Paper end - <desc>`; Canvas uses the same
pattern with the Canvas tag:

```java
// Canvas start - <short description of the change>
... your code ...
// Canvas end - <short description>
```

Rules:
- Every hunk that adds/modifies logic in a vanilla class gets a marking pair.
- The description must match the patch's single concern.
- For OG-absorbed changes, keep the original `// Canvas` markers if present;
  for our local delta, still use `// Canvas start - local: <desc>`.
- Do not nest marking pairs. Do not leave orphaned `// Canvas start` without a
  matching `// Canvas end`.

## Fully-Qualified Imports (Paper convention)

In vanilla (Minecraft) classes, prefer **fully-qualified imports** over adding
new import statements. Paper does this to keep patches minimal and rebase-safe
(adding imports is a common conflict source).

```java
// Bad — adds an import line that conflicts on rebase
import io.canvasmc.canvas.tick.CrsScheduler;
... CrsScheduler.schedule(...);

// Good — fully-qualified, no import added
io.canvasmc.canvas.tick.CrsScheduler.schedule(...);
```

Only add a new import if the type is used many times and the fully-qualified
form hurts readability. For Canvas-owned (non-vanilla) classes, normal imports
are fine.

## Base Patches (the important ones)

- Must have valid `index` lines (blob SHA1 from POST-AT state).
- Generate from the runCanvasSetup cache:
  ```bash
  cd canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
  # make your change as commits
  git format-patch -1 HEAD -o /path/to/base/{canvas,local}/
  ```
- Header should say origin: `[Canvas-OG]` or `[local]`.
- One logical change per patch. Number correctly.
- Self-contained — must apply independently of other base patches.

## Source Patches (per-file)

- `gitFilePatches = false` → use plain `patch`.
- Keep context stable (signatures, not body).
- Small hunks win on rebase.
- If many changes in one file over time → consider promoting to base patch.

## Minimal Hunk Rules

- **Minimal diff** — only the lines that change, plus the minimal context.
- **Stable context lines** — anchor hunks on method signatures or other stable
  lines, not on body code that churns. Unstable context = rebase conflicts.
- **Don't rename/move in source patches** — restructuring belongs in a dedicated
  base patch, not a source tweak.
- **One concern per patch** — if a patch touches two unrelated things, split it.

## Feature Patches

- Only for things we may want to drop later.
- Otherwise put in `local/` as normal base or source.

## Dual Upstream Hygiene

- Changes that came from Canvas OG → put resulting patch in `canvas/` subdir.
- Our delta / fixes / opinions → `local/`.
- When absorbing from OG later, compare against `canvas/`, not `local/`.
- See `/canvas-upstream-sync` for the full partitioning strategy.

## Common Workflow to Add a Patch

```bash
./gradlew applyAllPatches --no-configuration-cache   # get clean source
# edit in canvas-server/src/minecraft/java/...
# or paper-server/...
# Mark changes: // Canvas start - <desc> ... // Canvas end - <desc>
git add -A
git commit -m "local: your change"
./gradlew fixupMinecraftSourcePatches && ./gradlew rebuildMinecraftSourcePatches  # or base rebuild
# move the generated .patch into correct canvas/ or local/
# test apply again
```

## After Editing Patches

- Always `./gradlew applyAllPatches --no-configuration-cache`
- Compile + test
- Run `./rbp.sh` (the fixed version)
- Verify no new rejects

## Rebase-Safe Rules (from canvas-refactor-guard)

- Minimal diff
- Stable context lines (signatures, not body)
- AT instead of patch for visibility changes when possible (ATs survive rebases)
- Don't rename/move in source patches
- Big architecture in dedicated base patch
- Fully-qualified imports in vanilla classes (avoid import-line conflicts)
- One concern per patch

## Citations in commits / PRs

- Reference the originating DeepWiki page or OG commit
- `canvas-server/minecraft-patches/base/local/00xx-....patch`

Follow this and patches survive frequent Paper + Canvas OG upstreams + our own refactors.
