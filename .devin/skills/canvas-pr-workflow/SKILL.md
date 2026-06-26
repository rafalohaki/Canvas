---
name: canvas-pr-workflow
description: Use whenever creating or preparing a Canvas PR — patch formatting, commit style per CONTRIBUTING.md, PR description template, AI policy compliance, testing requirements, pre-PR checklist, release workflow (version bumping, changelog, paperclip jar distribution, GitHub release), and CI/CD setup (GitHub Actions build + upstream-check workflows). Triggers on "PR", "pull request", "submit", "create PR", "commit", "commit message", "PR description", "before PR", "pre-submit", "release", "version bump", "changelog", "CI", "GitHub Actions".
triggers:
  - user
allowed-tools:
  - read
  - grep
  - glob
  - exec
  - edit
argument-hint: "[pr-action]"
---

# Canvas PR Workflow

Create Canvas PRs that comply with `policies/CONTRIBUTING.md`,
`policies/REVIEWING.md`, and `policies/AI_POLICY.md`. Also covers release
workflow and CI/CD setup.

Triggers are `[user]` only — PR creation and releases are destructive
operations that require explicit user intent.

## Argument

`[pr-action]` — optional. One of: `prepare`, `create`, `release`, `ci`. When
omitted, runs the pre-PR checklist and prepares the PR.

## Pre-PR Checklist

### Code
- [ ] Patches apply: `./gradlew applyAllPatches --no-configuration-cache`
- [ ] Compiles: `./gradlew :canvas-server:compileJava && ./gradlew :canvas-api:compileJava`
- [ ] Tests pass: `./gradlew test`
- [ ] Patches rebuilt: `./rbp.sh`
- [ ] Runtime tested: `./gradlew runDev` (if behavior change)
- [ ] Region threading safe (see `/canvas-region-threading`, `/canvas-code-review`)
- [ ] Minimal diff (see `/canvas-refactor-guard`)
- [ ] Follows surrounding code style

### Patches
- [ ] Correct layer (base / source / feature)
- [ ] Sequential numbering, no gaps
- [ ] Base patches have `index` lines
- [ ] No empty patches removed (`filterPatches = false`)
- [ ] Patch headers describe the change

### AI Policy (`policies/AI_POLICY.md`)
- [ ] Human reviewed the AI-generated code
- [ ] AI was assistive, not a replacement
- [ ] Code is correct and properly constructed (not AI slop)
- [ ] Not fully AI-generated with zero human involvement
- [ ] No "Generated with Devin" footer in patch commits

## Patch Formatting for PRs

- Patches are git commits that become `.patch` files via `git format-patch`.
  Commit messages become patch headers.
- One concern per PR — split refactors from features from bugfixes.
- Minimal diff — every line is a future conflict with upstream.
- Run `./rbp.sh` before committing so patch files reflect source exactly.

```bash
# Verify patch health before PR
./rbp.sh --force
git diff --stat   # only intended patches should change
```

## Commit Style

Canvas uses git commits for base/feature patches (they become patch files via
`git format-patch`). Commit messages become patch headers.

```
Brief description of the change

Optional: longer explanation of why, if non-obvious.
```

- Keep the subject line short and descriptive
- Match existing patch header style (grep
  `canvas-server/minecraft-patches/base/` for examples)
- No "Generated with Devin" footer in patch commits — these become permanent
  patch headers

## PR Description Template (per `policies/CONTRIBUTING.md`)

Required:
- **Authors / co-authors**
- **What your PR changes and why**

If adding a feature:
- **Why is this feature useful? Who benefits?**

If fixing something:
- **Describe the issue**
- **Describe why your PR fixes it**

Full template:
```markdown
## Summary
- What changed and why

## Authors
- Your name

## Testing
- [x] ./gradlew applyAllPatches passes
- [x] ./gradlew :canvas-server:compileJava passes
- [x] ./gradlew test passes
- [x] ./gradlew runDev tested: <what you tested>

## Notes
- Any context for reviewers
```

## Creating the PR

```bash
# 1. Verify everything
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew test
./rbp.sh

# 2. Review the diff
git diff --stat
git diff

# 3. Commit (patch changes + source changes)
git add -A
git commit -m "Your change description"

# 4. Push and create PR
git push origin <branch>
gh pr create --title "Brief title" --body "$(cat <<'EOF'
## Summary
- What changed and why

## Authors
- Your name

## Testing
- [x] ./gradlew applyAllPatches passes
- [x] ./gradlew :canvas-server:compileJava passes
- [x] ./gradlew test passes
- [x] ./gradlew runDev tested: <what you tested>

## Notes
- Any context for reviewers
EOF
)"
```

## What Reviewers Expect (`policies/REVIEWING.md`)

1. **Thorough diff review** — reviewers check out the PR and apply patches to
   see the full diff
2. **Testing** — reviewers test locally; more testing = more confidence
3. **Communication before merge** — maintainers ask each other + the author
   before merging

Make this easy by:
- Clean, minimal patches
- Clear description of what + why
- Noting what you tested
- Being responsive to feedback

## Patch Header Examples

Look at existing patches for style:
```bash
head -10 canvas-server/minecraft-patches/base/0001-*.patch
head -10 canvas-server/minecraft-patches/base/0011-*.patch
head -10 canvas-server/minecraft-patches/features/0001-*.patch
```

## Release Workflow

### Version bumping
1. Update version in `gradle.properties` (e.g. `canvasVersion` /
   `mcVersion` / `apiVersion`).
2. Update `paperCommit` if the release includes an upstream bump.
3. Update `roadmap.md` summary if architecture changed.

### Changelog
- Summarize user-facing changes since the last release.
- Note config migrations (see `/canvas-config-system`).
- Note breaking changes for plugin authors (scheduler API, config keys).
- Cite PR numbers for traceability.

### Build the distributable
```bash
./gradlew clean
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-api:compileJava :canvas-server:compileJava
./gradlew test
./rbp.sh
./gradlew createPaperclipJar
```
- `createPaperclipJar` produces the paperclip jar — the release artifact.
- Verify the jar runs: `./gradlew runPaperclip` or launch it manually.

### GitHub release
```bash
gh release create <tag> build/libs/canvas-paperclip-*.jar \
  --title "Canvas <version>" \
  --notes "$(cat CHANGELOG.md)"
```
- Tag format: follow existing tags (check `git tag -l`).
- Attach the paperclip jar as a release asset.

## CI/CD Setup (GitHub Actions)

### Build workflow (`.github/workflows/build.yml`)
```yaml
name: build
on:
  push:
    branches: [ver/paper-base, main]
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '25'
      - uses: gradle/actions/setup-gradle@v4
      - run: ./gradlew applyAllPatches --no-configuration-cache
      - run: ./gradlew :canvas-api:compileJava :canvas-server:compileJava
      - run: ./gradlew test
      - run: ./rbp.sh
      - run: ./gradlew createPaperclipJar
      - uses: actions/upload-artifact@v4
        with:
          name: paperclip
          path: build/libs/canvas-paperclip-*.jar
```

### Upstream-check workflow (`.github/workflows/upstream-check.yml`)
Automates Paper upstream sync detection — fails when Paper has new commits
that Canvas hasn't absorbed.
```yaml
name: upstream-check
on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '25'
      - name: Compare Paper HEAD vs recorded commit
        run: |
          PAPER_COMMIT=$(grep '^paperCommit=' gradle.properties | cut -d= -f2)
          UPSTREAM_HEAD=$(git ls-remote https://github.com/PaperMC/Paper.git HEAD | awk '{print $1}')
          echo "Recorded: $PAPER_COMMIT"
          echo "Upstream: $UPSTREAM_HEAD"
          if [ "$PAPER_COMMIT" != "$UPSTREAM_HEAD" ]; then
            echo "::warning::Paper upstream has new commits. Run ./upstream.sh update"
            exit 1
          fi
      - name: Verify patches still apply
        if: always()
        run: ./gradlew applyAllPatches --no-configuration-cache
```
- Runs daily; fails when Paper drifts or patches no longer apply cleanly.
- Pair with `./upstream.sh update` (see `/canvas-upstream-sync`).

## PR Template Generator

A standard PR template with a test-plan checklist ensures every PR communicates
what changed, why, and how it was verified.

### Standard template

```markdown
## Summary
- <What changed and why — one concern per PR>

## Authors
- <Your name>

## Testing
- [ ] `./gradlew applyAllPatches --no-configuration-cache` passes
- [ ] `./gradlew :canvas-api:compileJava :canvas-server:compileJava` passes
- [ ] `./gradlew test` passes
- [ ] `./rbp.sh` run (patches reflect source exactly)
- [ ] `./gradlew runDev` tested: <describe scenario>
- [ ] Region threading safe (see /canvas-region-threading, /canvas-code-review)
- [ ] Minimal diff (see /canvas-refactor-patterns)
- [ ] Patches: correct layer, sequential numbering, no gaps
- [ ] AI Policy: human-reviewed, no "Generated with Devin" footer

## Notes
- <Context for reviewers — breaking changes, config migrations, plugin impact>
```

### Usage with `gh`

```bash
gh pr create --title "Brief title" --body "$(cat <<'EOF'
## Summary
- <what + why>

## Authors
- <name>

## Testing
- [x] ./gradlew applyAllPatches --no-configuration-cache passes
- [x] ./gradlew :canvas-api:compileJava :canvas-server:compileJava passes
- [x] ./gradlew test passes
- [x] ./rbp.sh run
- [x] ./gradlew runDev tested: <scenario>
- [x] Region threading safe
- [x] Minimal diff
- [x] Patches: correct layer, sequential, no gaps
- [x] AI Policy: human-reviewed, no AI footer

## Notes
- <context>
EOF
)"
```

### Checklist guidance

- **Check only what you actually did** — unchecked items are a signal to
  reviewers, not a formality. Don't check all boxes reflexively.
- **`runDev` scenario** — describe what you tested (e.g. "teleported players
  across regions, watched for IllegalStateException").
- **Breaking changes** — note in `## Notes` if plugin authors or server
  operators need to act (config migration, scheduler API change).
- **One concern per PR** — if the template's Summary has two unrelated
  changes, split the PR.

See `/canvas-release-workflow` (if created) for release-specific templates.

## Automated Changelog

Extracting the changelog from commit messages keeps it accurate and
traceable to PRs.

### Extracting changelog from commits

```bash
# Commits since the last release tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
git log --pretty=format:"- %s (%h)" "$LAST_TAG"..HEAD > changelog-since-last.txt

# Or grouped by conventional-commit type (if commits follow a convention)
git log --pretty=format:"%s" "$LAST_TAG"..HEAD \
  | grep -E "^(feat|fix|perf|refactor|docs|chore)" \
  | sort
```

### Conventional commit style (optional)

If commits follow `type(scope): description`:
- `feat:` → user-facing feature
- `fix:` → bug fix
- `perf:` → performance
- `refactor:` → internal change (not user-facing)
- `docs:` → documentation
- `chore:` → build/tooling

Group the changelog by type; only surface `feat`, `fix`, `perf` to users
unless a `refactor` is breaking.

### Changelog entry format

```markdown
## [unreleased]
### Features
- Add AFFINITY scheduler CPU affinity option (#123)
### Fixes
- Fix region split pinning transfer race (#124)
### Performance
- Reduce scheduler poll overhead under balanced load (#125)
### Breaking
- `scheduler` config now accepts `AFFINITY` (was `EDF`/`FIFO`) (#126)
```

- Cite PR numbers (`#NNN`) for traceability.
- Note config migrations and breaking changes for plugin authors / operators
  (see `/canvas-config-system` → Config Migration).
- Summarize user-facing changes; omit pure refactors unless breaking.
- The full release workflow (version bump, paperclip jar, GitHub release,
  Maven publishing) is in the **Release Workflow** section above and
  `/canvas-release-workflow` (if created).

## Pitfalls

1. **Don't commit generated `build.gradle.kts`** — only the `.patch` file.
2. **Don't remove empty patches** — `filterPatches = false` keeps them
   intentionally.
3. **Don't add "Generated with Devin" to patch commits** — they become
   permanent headers.
4. **Don't skip testing** — CONTRIBUTING.md requires it; reviewers will test
   too.
5. **Don't submit fully AI-generated PRs** — AI Policy: 3 strikes → ban.
6. **Don't mix concerns** — one PR = one logical change. Split refactors from
   features from bugfixes.
7. **Don't tag a release without `createPaperclipJar` succeeding** — the
   paperclip jar is the distributable.
