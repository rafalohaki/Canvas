---
name: canvas-code-review
description: Use whenever reviewing Canvas code changes, PRs, or patches — checks for region threading safety, patch layer correctness, minimal diff, code style consistency, AI policy compliance, and Canvas PR guidelines. Applies review patterns (bugs, security, style, logic, error handling) with constructive feedback citing file:line. Triggers on "review", "code review", "PR review", "review this", "check this change", "is this safe", "AI policy", "patch review".
triggers:
  - user
  - model
allowed-tools:
  - read
  - grep
  - glob
  - exec
argument-hint: "[pr-number-or-diff]"
subagent: true
---

# Canvas Code Review

Review Canvas changes against: region threading safety, patch layer
correctness, minimal diff, code style, and the Canvas AI Policy + PR
guidelines. Runs as a subagent so the review is self-contained and the
parent session can act on findings.

## Argument

`[pr-number-or-diff]` — optional. A GitHub PR number (review via `gh pr diff
<N>`) or a git ref/range (e.g. `HEAD~1`, `main..feature`). When omitted,
reviews the staged diff (`git diff --staged`).

## Review Workflow

1. **Acquire the diff**
   ```bash
   # PR by number
   gh pr diff <N>
   # Local ref/range
   git diff <range>
   # Staged
   git diff --staged
   ```
2. **Checkout and apply** — reviewers check out the PR and apply patches to
   see the **full** diff (rewrites/based-on code may not show in raw diff).
   Per `policies/REVIEWING.md`.
   ```bash
   ./gradlew applyAllPatches --no-configuration-cache
   git diff --stat   # did anything unexpected change?
   ```
3. **Run the review checklist** (below) against the full diff.
4. **Test locally** — `./gradlew runDev`, actually try the feature.
5. **Comment if you tested** — more testing = more confidence.
6. **For maintainers**: ask other maintainers + the author before merging.

## Review Checklist

### 1. Region Threading Safety (most critical)
- [ ] No off-thread access to region-owned data
- [ ] Correct scheduler used: `RegionScheduler` (by location),
      `EntityScheduler` (follows entity), `GlobalRegionScheduler` (global
      tick), `AsyncScheduler` (off-tick, no world access)
- [ ] No legacy global scheduler abuse
- [ ] `TickThread` guards where needed
- [ ] No `Bukkit.isPrimaryThread()` checks (always false on Canvas)

```bash
# Grep the diff for red flags
git diff --staged | grep -E "getScheduler\(\)\.runTask|Bukkit\.getScheduler|isPrimaryThread"
git diff --staged | grep -E "\.getLocation\(\)|\.getBlockAt\("  # check context — async?
```

### 2. Patch Layer & Dual Upstream Hygiene
- [ ] Correct layer: base (`minecraft-patches/base/`) for architectural,
      source (`minecraft-patches/sources/`) for per-file, feature
      (`minecraft-patches/features/`) for optional
- [ ] Correct subdir after partitioning: `canvas/` (absorbed from OG) vs
      `local/` (our delta)
- [ ] Visibility-only changes → AT (`build-data/canvas.at`), not a patch
- [ ] Base patch has `index` lines (required for `git am --3way`)
- [ ] Patch numbering is sequential, no gaps
- [ ] No mixing of origins in one patch
- [ ] If architecture change: dedicated base patch, documented

### 3. Minimal Diff
- [ ] No unnecessary reformatting of surrounding code
- [ ] No blank-line additions/removals unrelated to the change
- [ ] No commented-out code left in
- [ ] Context lines are stable (unlikely to change upstream)
- [ ] One concern per patch (no refactor + feature + bugfix mix)

```bash
git diff --staged --stat
# Large diff for a small logical change? Review for bloat.
```

### 4. Code Style Consistency
- [ ] Follows surrounding code style (indentation, braces, naming) per
      `policies/CONTRIBUTING.md`
- [ ] No sharp style changes amidst consistent code
- [ ] Java 25 idioms where appropriate
- [ ] No unnecessary imports (run `fixupMinecraftSourcePatches` to normalize)

### 5. AI Policy Compliance (`policies/AI_POLICY.md`)
- [ ] Change is reviewed by a human, not blindly AI-generated
- [ ] AI was an assistive tool, not a replacement
- [ ] Code is correct and properly constructed (not AI slop)
- [ ] If fully AI-generated with no review: flag per the 3-strikes policy

### 6. Canvas PR Guidelines (`policies/CONTRIBUTING.md` + `REVIEWING.md`)
- [ ] Description includes: authors, what changed + why
- [ ] New features: why is it useful? Who benefits?
- [ ] Bug fixes: what's the issue + why does this fix it
- [ ] Patches are neat and tidy, no unnecessary diff
- [ ] Changes were tested locally

## Security Checklist

Review every change for basic security issues:

- [ ] **No secrets hardcoded** — no API keys, tokens, passwords, or private
      keys in source, patches, or config. Check for base64-encoded secrets too.
- [ ] **No SQL injection** — if any database/query code is touched, verify
      parameterized queries or prepared statements are used. No string
      concatenation for SQL.
- [ ] **Input validation** — all external input (player commands, config
      values, network packets) is validated before use. Check for:
      - Unbounded string lengths (DoS via memory)
      - Negative or zero values where positive expected
      - Null without `@Nullable` annotation or null check
- [ ] **No command injection** — if `Runtime.exec()` or `ProcessBuilder` is
      used, input must be sanitized. No player-controlled strings in shell
      commands.
- [ ] **No path traversal** — file paths from user input are sanitized
      (no `../` escaping). Use `Path.normalize()` + `startsWith()` checks.
- [ ] **No unsafe deserialization** — no `ObjectInputStream` on untrusted
      data. Use JSON or explicit serialization.
- [ ] **Permission checks not bypassed** — command handlers still enforce
      permissions. Patches don't skip `PermissionAttachment` or `hasPermission()`.
- [ ] **No information leakage** — error messages don't expose internal
      paths, stack traces, or system info to players.

```bash
# Grep for common security red flags in the diff
git diff --staged | grep -iE "password|secret|token|api.key|private.key"
git diff --staged | grep -E "Runtime\.getRuntime\(\)\.exec|ProcessBuilder"
git diff --staged | grep -E "ObjectInputStream|readObject\("
git diff --staged | grep -E "SELECT.*\+|INSERT.*\+"  # SQL concatenation
```

See `/canvas-security-review` for a deep security audit skill.

## Performance Checklist

Review every change for performance issues, especially in hot paths:

- [ ] **Hot path identification** — is the changed code in a tick loop,
      chunk loading, entity ticking, or packet handling? If so, every
      allocation matters.
      ```bash
      # Check if the changed file is in a tick-critical path
      grep -rl "tick\|Tick\|TICK" canvas-server/src/minecraft/java/<path>
      ```
- [ ] **No allocation in tick** — avoid `new` in hot paths:
      - No `new ArrayList<>()`, `new HashMap<>()`, `new Object[...]` per tick.
      - No autoboxing (`Integer.valueOf()` from `int` in collections).
      - No `String.format()` or string concatenation in logging unless
        the log level is enabled.
      - No lambda capture (creates a synthetic object) in tight loops.
- [ ] **No unnecessary boxing** — `Integer`/`Double` where `int`/`double`
      suffices. Use primitive collections (fastutil) if needed.
- [ ] **No O(n²) in hot paths** — check loop nesting. Entity lists and
      chunk iteration can be large.
- [ ] **No blocking I/O on tick thread** — file reads, network calls, or
      `Thread.sleep()` on a tick thread stalls the region.
- [ ] **No excessive synchronization** — `synchronized` blocks in tick
      paths cause contention. Use lock-free structures or region-local access.
- [ ] **Cache reuse** — repeated computations (e.g., config lookups) are
      cached, not recomputed every tick.
- [ ] **No iterator allocation** — use `for (int i = 0; i < list.size(); i++)`
      instead of `for (var x : list)` in ultra-hot paths (iterator object
      allocation).

```bash
# Grep for allocation patterns in the diff
git diff --staged | grep -E "new (ArrayList|HashMap|HashSet|Object\[)"
git diff --staged | grep -E "Thread\.sleep|\.wait\(\)|\.join\(\)"
git diff --staged | grep -E "synchronized.*\{"
```

## Review Patterns (from awesome-agent-skills)

Apply each pattern to every diff hunk:

### Bugs
- Off-by-one errors in loops, indexes, ranges
- Null dereferences — check guards before `.get()` / field access
- Resource leaks (unclosed streams, channels, file handles)
- Incorrect default values (mismatched between config field and logic)
- Race conditions on shared mutable state (region threading context)

### Security
- Untrusted input reaching file I/O, command dispatch, or serialization
- SQL/JSON injection if any DB or config parsing is involved
- Permissions checks bypassed by the patch (e.g., command handler skips
  `PermissionAttachment`)
- Secrets/tokens hardcoded (should never happen in Canvas source, but check)

### Style
- Inconsistent naming vs neighbors (camelCase vs kebab-case in config keys)
- Dead code, unused imports, unused fields
- Magic numbers without a named constant or comment

### Logic errors
- Inverted conditions (`==` vs `!=`)
- Wrong scheduler chosen for the data being touched
- Early return that skips a required cleanup/side effect
- Default branch in switch missing or fall-through unintended

### Missing error handling
- `Optional.get()` without `isPresent()` / `orElse`
- Ignored `Future` / `CompletableFuture` results
- Exceptions swallowed with empty `catch` blocks
- Missing `try-finally` around region-scheduled work that must release a
  resource

## Constructive Feedback Format

For each finding, cite `file:line` and suggest a concrete improvement:

```
[CRITICAL] canvas-server/src/minecraft/java/.../Foo.java:142
  Issue:   Bukkit.getScheduler().runTask(...) — no main thread on Canvas.
  Why:     Region threading; this accesses world data off the owning thread.
  Suggest: Bukkit.getRegionScheduler().execute(location, () -> { ... });
```

Severity levels:
- `[CRITICAL]` — build-breaking, region threading violation, data corruption
- `[MAJOR]` — logic error, missing error handling, security issue
- `[MINOR]` — style, naming, minor diff bloat
- `[NIT]` — subjective, optional

## Quick Verification Commands

```bash
# Apply and check
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew test

# Check patch health
./rbp.sh --force    # do all patches regenerate cleanly?
git diff --stat     # did anything unexpected change?

# Runtime test
./gradlew runDev    # load the feature, watch for errors
```

## Red Flags (reject or request changes)

- Region threading violations (off-thread world access)
- `Bukkit.getScheduler()` legacy calls
- Base patch without `index` lines
- AT removed that base patches depend on
- Massive reformatting unrelated to the change
- No description / no testing noted
- Fully AI-generated with zero human review (AI Policy violation)
- Mixed concerns in one patch (refactor + feature + bugfix)

## Cross-References

- `/canvas-security-review` — deep security audit (secrets, injection, permissions)
- `/canvas-verify-build` — full verification pipeline after review
- `/canvas-refactor-patterns` — safe refactoring patterns
- `/canvas-patch-authoring` — patch layer rules, marking conventions

## Output Format

Provide review as:
1. **Summary**: approve / request changes / reject
2. **Critical issues**: region threading, build-breaking — cite file:line
3. **Major issues**: logic, error handling, security — cite file:line
4. **Security issues**: secrets, injection, permissions — cite file:line
5. **Performance issues**: hot path, allocation, boxing — cite file:line
6. **Style/minimal-diff issues**: suggestions — cite file:line
7. **Testing notes**: what to test, how
8. **AI policy note**: if applicable
