---
name: canvas-build-system
description: Use whenever working with the Canvas Gradle build — Weaver plugin config, build.gradle.kts, build.gradle.kts.patch files, Java 25 toolchain, configuration cache, subproject setup, maven publishing, debug/plugin projects, or build failures. Triggers on "build", "gradle", "build.gradle.kts", "weaver", "compileJava fails", "build task", "createPaperclipJar", "toolchain", "Java 25".
argument-hint: "[task]"
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

# Canvas Build System

Canvas uses Gradle (9.5.1) with the **Weaver** patcher plugin
(`io.canvasmc.weaver.patcher` v2.4.5), a Paperweight fork. Java 25 toolchain.

**Always read `build.gradle.kts` and `gradle.properties` before modifying build config.**

## Key Files

| File | Purpose |
|------|---------|
| `build.gradle.kts` | Root: Weaver config, subproject defaults, Java 25 toolchain |
| `gradle.properties` | `paperCommit`, `mcVersion`, `apiVersion`, cache flags, JVM args |
| `settings.gradle.kts` | Multi-project structure (`canvas-api`, `canvas-server`) |
| `canvas-server/build.gradle.kts.patch` | Patch on Paper's `paper-server/build.gradle.kts` |
| `canvas-api/build.gradle.kts.patch` | Patch on Paper's `paper-api/build.gradle.kts` |

## Weaver Config (root build.gradle.kts)

```kotlin
paperweight {
    filterPatches = false          // keep empty patches
    gitFilePatches = false         // source patches use `patch`, not `git am`
    upstreams.paper {
        repo = github("PaperMC", "Paper")
        ref = providers.gradleProperty("paperCommit")
        applyUpstreamNested.set(false)
        patchFile { /* paper-server/build.gradle.kts → canvas-server/build.gradle.kts */ }
        patchFile { /* paper-api/build.gradle.kts → canvas-api/build.gradle.kts */ }
        patchDir("paperApi") { /* paper-api → paper-api output, excludes build.gradle.kts */ }
    }
}
```

`patchFile` = unified diff on a single file. `patchRepo` = git patches on a repo.
`patchDir` = copy + apply file patches on a directory.

## Subproject Defaults

All subprojects get:
- `java-library` + `maven-publish` plugins
- Java 25 toolchain, `options.release = 25`
- `-Xlint:-deprecation -Xlint:-removal` compiler args
- UTF-8 encoding everywhere
- Test logging: full stack traces + stdout
- PatchRoulette endpoint: `https://patch-roulette.canvasmc.io/api`
- Maven publish to `https://maven.canvasmc.io/releases` (env: `PUBLISH_USER` / `PUBLISH_TOKEN`)

## Debug / Plugin Projects

Projects ending in `-debug` or `-plugin` get:
- `xyz.jpenilla.resource-factory-paper-convention` plugin
- `compileOnly(rootProject.projects.canvasServer)` runtime elements
- `foliaSupported = true` (or canvas-supported equivalent) in paper-plugin.yml — required for region threading plugins
- `apiVersion` from gradle.properties, `version = "SNAPSHOT-DEV"`

These load automatically in `runDev`.

These are for runtime testing — `runDev` loads jars from `*-plugin` / `*-debug` dirs.

## Build Tasks

```bash
./gradlew applyAllPatches              # Apply all patches → source dirs
./gradlew createPaperclipJar           # Build the paperclip server jar
./gradlew runDev                       # Start dev server (auto-loads plugins)
./gradlew test                         # Unit tests
./gradlew :canvas-server:compileJava   # Just compile server
./gradlew :canvas-api:compileJava      # Just compile API
```

## Configuration Cache

`gradle.properties` enables: `configuration-cache`, `caching`, `parallel`, `vfs.watch = false`.

**When config-cache causes stale issues**, add `--no-configuration-cache`:
```bash
./gradlew applyAllPatches --no-configuration-cache
```

## Editing build.gradle.kts

The `canvas-server/build.gradle.kts` and `canvas-api/build.gradle.kts` are
**generated** from patches. To change them:

1. Edit `canvas-server/build.gradle.kts.patch` (or `canvas-api/...`)
2. Run `./gradlew rebuildFoliaSingleFilePatches` (legacy task name, still used)
3. Or edit the generated file then `./rbp.sh --gradle`

**Do not commit the generated `build.gradle.kts`** — only the `.patch` file.

## AT Files

Canvas uses 4 Access Transformer files in `build-data/`:

| File | Purpose | Edit? |
|------|---------|-------|
| `build-data/canvas.at` | Canvas-original ATs | Yes |
| `build-data/folia.at` | Folia-originated ATs (absorbed from upstream Canvas) | Yes |
| `build-data/paperApi.at` | Upstream Paper API ATs | No (overwritten on sync) |
| `build-data/paperServer.at` | Upstream Paper server ATs | No (overwritten on sync) |

All 4 are applied in `runCanvasSetup` before base patches (POST-AT state).
See `/canvas-at-guard` for syntax and the POST-AT dependency cycle.

## Build Performance

Canvas enables configuration cache, build cache, and parallel execution in
`gradle.properties`. Tips for faster builds:

### Configuration cache reuse
- Configuration cache is enabled (`org.gradle.configuration-cache=true`).
- After a `paperCommit` bump or AT change, always use
  `--no-configuration-cache` once to rebuild the cache.
- Subsequent builds reuse the cached configuration graph — much faster.
- If builds feel stale or wrong, clear the cache:
  `rm -rf .gradle/configuration-cache`

### Parallel execution
- `org.gradle.parallel=true` — subprojects build in parallel.
- `canvas-api` and `canvas-server` compile concurrently when possible.
- Don't disable parallel unless debugging a race in the build itself.

### Daemon settings
- Gradle daemon is enabled by default (`org.gradle.daemon=true`).
- JVM args in `gradle.properties` (`org.gradle.jvmargs`) — increase heap if
  you see `OutOfMemoryError` during `applyAllPatches`:
  `org.gradle.jvmargs=-Xmx4G` (or higher for large patch sets).
- Daemon restarts automatically after `gradle.properties` changes.
- To force daemon stop: `./gradlew --stop`

### Build cache
- `org.gradle.caching=true` — task outputs are cached and reused.
- Combined with configuration cache, incremental builds are very fast.
- `--no-build-cache` if you suspect a cache corruption issue.

## Common Build Failures

| Error | Cause | Fix |
|-------|-------|-----|
| `sha1 information is lacking` | Base patch missing `index` lines | Regenerate via `git format-patch` from POST-AT state |
| `patch does not apply` | Source patch context drift | Fix hunk line numbers / context |
| `Java 25 not found` | Toolchain not downloaded | `./gradlew --refresh-dependencies` or install JDK 25 |
| Config-cache stale | Cached task graph outdated | `--no-configuration-cache` |
| `paperCommit` not found | Bad commit hash in gradle.properties | `./upstream.sh update` |
| `folia.at not found` | `build-data/folia.at` missing (new AT file) | Ensure `build-data/folia.at` exists — absorbed from upstream Canvas. Create empty file if needed, or sync from upstream. |

## Verification

After any build config change:
```bash
./gradlew applyAllPatches --no-configuration-cache   # patches apply
./gradlew :canvas-server:compileJava                 # server compiles
./gradlew :canvas-api:compileJava                    # API compiles
```
