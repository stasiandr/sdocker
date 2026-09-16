# sdocker

Native macOS Docker client: SwiftUI on top of [Colima](https://github.com/abiosoft/colima).
Images and builds for now, the rest when it's needed.

```bash
scripts/bundle.sh        # → build/sdocker.app
open build/sdocker.app
```

- **Images** — table with size, platforms and "in use", Docker Hub–style layer view
  (instruction + layer size) and config in the inspector; pull (⌘N) with progress, tag,
  remove, prune dangling.
- **Builds** — BuildKit history, including builds run from the terminal; build detail with
  steps, cached steps, per-step logs, the failing Dockerfile snippet, info; new build (⌘B)
  from a folder: Dockerfile, target stage, tags, build args, platforms, no-cache/pull;
  live progress, cancel, build again.
- Sidebar footer shows the engine and starts/stops Colima.

Needs `colima`, `docker` and `docker-buildx` from Homebrew (buildx needs
`"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]` in `~/.docker/config.json`).
Only Command Line Tools, no Xcode project.

## How it talks to Docker

- `Engine/DockerAPI.swift` — a small HTTP/1.1 client for the Engine API over the unix socket
  of the current docker context (images, pull, tag, prune).
- Builds go through the CLI: `docker buildx build --progress rawjson` and
  `docker buildx history ls/inspect/logs`. `Builds/BuildProgress.swift` folds the rawjson
  stream into steps, for live builds and history alike.

Launch arguments for scripted screenshots: `-section builds`, `-select <repository>`,
`-open <build ref>`, `-build <folder>`.
