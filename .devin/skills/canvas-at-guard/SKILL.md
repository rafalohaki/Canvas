---
name: canvas-at-guard
description: Use Access Transformers (build-data/canvas.at) correctly. Prefer AT over patch for making things public/protected when possible. ATs survive rebases better. Know POST-AT vs PRE-AT impact on base patches. Covers AT syntax, modifier options, when AT vs source patch, adding/removing workflow, verification, and pitfalls. Triggers on "AT", "access transformer", "make public", "canvas.at", "private field", "visibility", "access transformer syntax", "AT vs patch".
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

# Canvas Access Transformer Guard

## Why ATs Matter Here

Canvas ATs (`build-data/canvas.at`) replicate the visibility changes that Folia
patches expected. They are applied in `runCanvasSetup` **before** base patches
(DeepWiki: Weaver task flow). This is why Folia-absorbed patches apply cleanly —
zero rejects on POST-AT state vs 33 rejects on PRE-AT (roadmap.md).

ATs are **more rebase-safe** than patches for visibility changes.

## File Layout

- `build-data/canvas.at` — Canvas-original ATs (our additions). Edit this.
- `build-data/folia.at` — Folia-originated ATs (absorbed from upstream Canvas).
  Edit this for Folia-specific visibility changes.
- `build-data/paperApi.at`, `paperServer.at` — upstream Paper, do not edit.
- Total effective ATs = paper + canvas + folia.

## AT Syntax

Each line: `<modifier> <fully-qualified-class> <member> [<descriptor>] [# comment]`

```
# Field — just the field name
public net.minecraft.server.MinecraftServer isRestarting

# Method — full signature with JVM descriptor
public net.minecraft.server.ServerTickRateManager finishTickSprint()V

# CraftBukkit field (paperServer.at example)
public org.bukkit.craftbukkit.CraftServer worlds
```

### Modifier Options

| Modifier | Effect |
|----------|--------|
| `public` | Sets member to `public` |
| `protected` | Sets member to `protected` |
| `private` | Sets member to `private` (rare) |
| `default` | Package-private (rare) |
| `public-f` | `public` + remove `final` modifier |
| `protected-f` | `protected` + remove `final` |
| `private-f` | `private` + remove `final` |
| `default-f` | Package-private + remove `final` |

The `-f` suffix strips `final` so the field/method can be overridden or
reassigned. See `build-data/canvas.at:3` for `default-f` example,
`:4-5` for `private-f`, `:10` for `protected-f`.

### Rules

- Classes use `$` for inner classes: `net.minecraft.world.level.block.state.BlockBehaviour$BlockStateBase$Cache`
- Method ATs need the **full JVM descriptor** including return type: `()V`, `(Lnet/minecraft/world/damagesource/DamageSource;)Z`
- Field ATs need only the field name, no descriptor
- One member per line
- Comments with `#` are optional but encouraged

## folia.at vs canvas.at

Canvas now has two editable AT files. Use the correct one:

| File | What goes here | Origin |
|------|----------------|--------|
| `build-data/folia.at` | Visibility changes that Folia patches expected (e.g., `ThreadedRegionizer` fields, `TickThread` internals) | Folia-origin, absorbed from upstream Canvas |
| `build-data/canvas.at` | Canvas-original visibility changes (our own additions not from Folia) | Canvas-original |

### Rules
- **Folia-originated ATs → `folia.at`** — if the visibility change exists in
  Folia's codebase or was part of Folia's patch set, it goes in `folia.at`.
- **Canvas-original ATs → `canvas.at`** — if we invented the need for the
  visibility change (no Folia precedent), it goes in `canvas.at`.
- **Never duplicate** — if an entry exists in `folia.at`, don't also add it
  to `canvas.at`. See "AT Deduplication" below.
- **Provenance matters** — keeping Folia ATs separate makes upstream Canvas
  sync easier (we can diff `folia.at` against upstream's version).
- **Both are applied in `runCanvasSetup`** — there's no ordering difference.
  Both files contribute to the POST-AT state before base patches.

### How to decide
```bash
# Check if Folia has this visibility change
grep "<member>" build-data/folia.at
# If yes → it's Folia-origin, keep/update in folia.at
# If no → it's Canvas-original, put in canvas.at
```

## AT Deduplication

Detect and remove duplicate AT entries across files:

### Detection
```bash
# Find duplicate entries across all AT files
# Extract just the class+member (ignore modifier and comment)
sort build-data/canvas.at build-data/folia.at | \
  grep -v "^#" | grep -v "^$" | \
  awk '{print $2, $3, $4}' | sort | uniq -d

# Check if a specific member is in multiple files
grep "<ClassName> <member>" build-data/canvas.at build-data/folia.at build-data/paperApi.at build-data/paperServer.at
```

### Common duplication scenarios
1. **Same entry in `canvas.at` and `folia.at`** — pick one based on origin
   (see "folia.at vs canvas.at"). Remove the duplicate.
2. **Same entry in `canvas.at` and `paperServer.at`** — upstream Paper added
   the visibility change. Remove our entry (it's now redundant). See "AT
   Validation" below.
3. **Same member, different modifier** (e.g., `public` in `canvas.at`,
   `public-f` in `folia.at`) — pick the one with the needed modifier. If
   both are needed, keep the more permissive one and document why.

### Cleanup procedure
1. Identify duplicates (commands above).
2. For each duplicate, determine which file should keep the entry (origin rule).
3. Remove from the other file.
4. Clean cache + re-apply:
   ```bash
   rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
   ./gradlew applyAllPatches --no-configuration-cache
   ```
5. Compile + test to confirm nothing broke.
6. Rebuild affected base patches if needed.

## AT Validation

Verify that AT entries are still needed (the target may already be public in
upstream source):

### Validation procedure
For each AT entry, check if the target is already public/protected in the
upstream source (without our AT):

```bash
# 1. Apply only Paper (no Canvas ATs) to see upstream visibility
#    Temporarily comment out the AT line, clean cache, re-apply
#    Then check the field/method modifier in applied source

# 2. Check the modifier in the applied source
grep -n "<member>" canvas-server/src/minecraft/java/<path-to-file>
# Look at the declaration — is it already public/protected?

# 3. If already public → remove the AT entry (redundant)
# 4. If still private → keep the AT entry (still needed)
```

### Batch validation
```bash
# For each line in canvas.at (non-comment, non-empty):
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  class=$(echo "$line" | awk '{print $2}')
  member=$(echo "$line" | awk '{print $3}')
  echo "Checking: $class $member"
  # Find the file and check visibility
  filepath=$(echo "$class" | tr '.' '/' | sed 's|^|canvas-server/src/minecraft/java/|;s|$|.java|')
  grep -n "$member" "$filepath" 2>/dev/null | head -1
done < build-data/canvas.at
```

### When to validate
- **After every Paper upstream sync** — upstream may have changed visibility.
- **After every MC version migration** — new versions often refactor visibility.
- **Quarterly health check** — even without upstream changes, validate
  periodically.
- **Before a release** — remove redundant ATs to keep the file clean.

### What to do with redundant ATs
1. Remove the line from the AT file.
2. Check if any patches/code depend on the AT (they shouldn't if it's
   already public, but verify):
   ```bash
   grep -rn "<member>" canvas-server/src/minecraft/java/ canvas-server/minecraft-patches/
   ```
3. Clean cache + re-apply + compile + test.
4. Document the removal in `roadmap.md`.

## When to Use AT vs Source Patch

| Need | Use AT | Use Patch |
|------|--------|-----------|
| Read/write a private field from our code | Yes | No |
| Call a private method from our code | Yes | No |
| Remove `final` from a field/method | Yes (`-f` suffix`) | No |
| Change method body / behavior | No | Yes |
| Replace implementation | No | Yes |
| Add new method/field | No | Yes (base patch) |
| Change more than visibility | No | Yes |

**Rule:** AT for visibility only. Patch for behavior. AT survives upstream
renames better — you update one line in `canvas.at` instead of fixing every
call site in a 500-line patch.

## Critical Timing: POST-AT Dependency Cycle

Base patches (`git am --3way`) are applied on the **POST-AT** state from the
`runCanvasSetup` cache (DeepWiki: Weaver task flow, `applyMinecraftBasePatches`
clones the cache).

```
runCanvasSetup
  → Paper source (paperCommit)
  → Paper ATs (paperApi.at + paperServer.at)
  → Paper patches (927 patches)
  → Canvas ATs (canvas.at)           ← applied HERE
  → POST-AT cache repo
        ↓
applyMinecraftBasePatches
  → clones POST-AT cache
  → git am --3way base patches        ← base patches see AT-applied visibility
```

**POST-AT dependency cycle:** If you add an AT for something a base patch
touches:
1. The base patch was written against the old visibility.
2. After adding the AT, the base patch may now fail (context changed) or
   succeed but produce different code (field now public → different access).
3. You must re-apply / adjust the base patch on fresh POST-AT state.
4. Regenerate the base patch with `git format-patch` from POST-AT to get
   correct `index` lines (blob SHA1s).

**Rule:** AT changes that affect base-patched files require regenerating those
base patches.

## Adding an AT — Workflow

```bash
# 1. Edit build-data/canvas.at — add your line with a comment
#    e.g.: public net.minecraft.server.MinecraftServer isReady # Canvas - scheduler access

# 2. Clean the runCanvasSetup cache (ATs are cached)
rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/

# 3. Re-apply to get new POST-AT state
./gradlew applyAllPatches --no-configuration-cache

# 4. If base patches now fail or need update: fix in canvas-server/src/minecraft/java/
#    or in the cache repo directly, then regenerate

# 5. Rebuild affected base patches
./rbp.sh
# or: ./gradlew rebuildMinecraftBasePatches --no-configuration-cache

# 6. Verify (see below)
```

## Removing an AT — Workflow

```bash
# 1. Remove the line from build-data/canvas.at
# 2. Check which patches/code depend on the visibility:
grep -rn "<field-or-method-name>" canvas-server/src/minecraft/java/ canvas-server/minecraft-patches/
# 3. If anything references it, you need a source patch to restore visibility
#    or remove the dependent code
# 4. Clean cache + re-apply
rm -rf canvas-server/.gradle/caches/paperweight/taskCache/runCanvasSetup/
./gradlew applyAllPatches --no-configuration-cache
# 5. Fix any base patches that relied on the AT
# 6. Rebuild + verify
```

## Verifying AT Application

After any AT change:

```bash
# 1. Patches apply cleanly
./gradlew applyAllPatches --no-configuration-cache

# 2. Check the AT actually took effect in applied source
#    Look for the field/method — it should now have the new modifier
grep -n "<member>" canvas-server/src/minecraft/java/<path-to-file>

# 3. Compile
./gradlew :canvas-server:compileJava
./gradlew :canvas-api:compileJava

# 4. Test
./gradlew test

# 5. Verify only intended visibility changed — don't accidentally expose too much
```

## Best Practices

- Keep `canvas.at` entries minimal and commented.
- Group related ATs together with a section comment.
- When upstream Paper adds similar visibility, consider removing our duplicate
  entry (but test — Paper's AT might target a different descriptor).
- Document in patch headers when a patch **relies** on specific AT entries.
- For dual upstream: if Canvas OG adds ATs we need, merge them into `canvas.at`
  and note the `canvasCommit`.
- Prefer fully-qualified imports in vanilla classes to prevent patch conflicts
  (Paper marking convention — see `/canvas-patch-authoring`).

## Common Pitfalls

1. **ATs apply before patches** — base patches see POST-AT visibility. If a
   base patch was written against private visibility and you AT it public, the
   patch context may drift. Regenerate the base patch.
2. **Never AT a field Canvas adds via patch** — if Canvas adds a new field in
   a base patch, it's already our code. AT it in the patch directly, not in
   `canvas.at`. ATs only apply to **existing** upstream members.
3. **Method ATs need full signature** — missing the JVM descriptor
   (`()V`, `(Lnet/minecraft/...;)Z`) causes silent failure or wrong method
   match. Always include the descriptor for methods.
4. **Editing `paper*.at` instead of `canvas.at`** — upstream files get
   overwritten on sync. Only edit `build-data/canvas.at`.
5. **Adding AT but not re-running `applyAllPatches`** — the cache is stale,
   your AT won't take effect until you clean + re-apply.
6. **Forgetting `index` lines** — base patches generated from POST-AT must
   have valid blob SHA1s. Use `git format-patch` from the cache repo.
7. **Large patches instead of small AT + tiny patch** — if you only need
   visibility, use AT. Don't patch every call site.

## Paper Marking Convention

When ATs enable access in patches, follow Paper's marking convention for
multi-line additions:

```
// Paper start - <description>
... code ...
// Paper end - <description>
```

Single-line:
```
// Paper - <description>
```

This helps upstream sync identify which lines are ours during rebases.

## Cross-References

- `/canvas-weaver-internals` — `runCanvasSetup` cache, `applyMinecraftBasePatches` task flow
- `/canvas-patch-authoring` — base patch generation from POST-AT state
- `/canvas-upstream-sync` — AT changes during upstream sync
- `/canvas-refactor-patterns` — AT over patch principle

Sources: DeepWiki (Weaver task flow, AT application order), `build-data/canvas.at`,
`build-data/paperServer.at:9`, `roadmap.md` (POST-AT discovery).
