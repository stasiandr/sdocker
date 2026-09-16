# sdocker

Native macOS Docker client: SwiftUI on top of [Colima](https://github.com/abiosoft/colima).
A lightweight Docker Desktop for Colima.

```bash
scripts/bundle.sh        # → build/sdocker.app
open build/sdocker.app
```

- **Containers** — live table grouped by Compose project, with status, clickable ports, CPU
  and memory; start/stop/restart/pause/delete. A container page has live **logs** (filter,
  timestamps, follow), **stats** charts, **exec** of one-off commands, a **file browser** with
  "Save to Mac", and **inspect** (command, ports, mounts, networks, env, labels). Terminal opens
  an interactive shell in Ghostty. **Run** (⇧⌘N) from any image: name, ports, volumes or host
  folders, env, network, restart policy.
- **Images** — table with size, platforms and "in use", Docker Hub–style layer view
  (instruction + layer size) and config in the inspector; pull (⌘N) with progress, run, tag,
  remove, prune dangling.
- **Volumes** — size and the containers using each volume, file browser and download
  (through a throwaway read-only `alpine` container), create, delete, remove unused.
- **Networks** — subnet, gateway and member containers with their IPs; create bridge
  networks, delete, remove unused.
- **Builds** — BuildKit history, including builds run from the terminal; build detail with
  steps, cached steps, per-step logs, the failing Dockerfile snippet, info; new build (⌘B)
  from a folder: Dockerfile, target stage, tags, build args, platforms, no-cache/pull;
  live progress, cancel, build again.
- **Engine** — start/stop Colima, change CPUs, memory and disk (restarts the VM), Docker disk
  usage by images, containers, volumes and build cache with one-click cleanup.

Needs `colima`, `docker` and `docker-buildx` from Homebrew (buildx needs
`"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]` in `~/.docker/config.json`).
No Xcode project, but the icon is an Icon Composer document (`Resources/SDocker.icon`) compiled by `actool`, which needs Xcode 26 or later.

## How it talks to Docker

- `Engine/DockerAPI.swift` — a small HTTP/1.1 client for the Engine API over the unix socket
  of the current docker context: containers, logs and stats streams (cancelled with the view),
  exec, images, volumes, networks, disk usage.
- Builds go through the CLI: `docker buildx build --progress rawjson` and
  `docker buildx history ls/inspect/logs`. `Builds/BuildProgress.swift` folds the rawjson
  stream into steps, for live builds and history alike.

Launch arguments for scripted screenshots: `-section builds`, `-select <repository>`,
`-open <container, volume or build ref>`, `-tab stats`, `-build <folder>`.

## License

Public domain ([Unlicense](LICENSE)).
