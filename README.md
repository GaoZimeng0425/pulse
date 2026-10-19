# Pulse

**English** | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![UI](https://img.shields.io/badge/UI-SwiftUI-0096FF?logo=swift&logoColor=white)
![Root](https://img.shields.io/badge/root-not%20required-success)
![Tests](https://img.shields.io/badge/unit%20tests-535-green)

A native macOS menu bar system monitor that answers the question Activity Monitor won't: **what is actually eating my machine?** Not a 1000-row process list — app groups, project-level attribution, and the one process that matters, down to its cwd and full argv.

<p align="center">
  <img src="docs/screenshots/popover.png" width="31%" alt="Pulse popover">
  <img src="docs/screenshots/main-overview.png" width="55%" alt="Pulse main window, overview">
</p>

## Why Pulse

> One afternoon my Mac hit **load 52**. The truth: two worktrees of the same repo running quality gates (`cargo test` + `vitest --coverage`) at the same time, one resident app quietly burning 60% of a core, and an OrbStack VM sitting at 86%.
>
> Activity Monitor hands you a 1000-row process list. Pulse collapses it into three rows — and every row drills down to the process tree, start time, cwd, and full argv.

Pulse starts as a faithful clone of [Vitals](https://vitalsmac.com)'s UI and metric semantics, then goes deeper where Vitals doesn't: **project / session-level attribution**.

## Features

### Menu bar, always on

Configurable readouts — pick 1–3 slots from CPU, memory, disk, or network. Numbers change color with memory pressure; CPU turns red past 70%.

<p align="center"><img src="docs/screenshots/menu-bar.png" width="280" alt="menu bar badges"></p>

### Popover: everything at a glance

Click the badge for all five domains — CPU, memory, disk, network, battery — with sparklines, plus the busiest app groups right now. All groups are listed, not a top-5 cut.

### Main window: seven module pages

Overview, CPU, memory, disk, network, battery, and history — switch from the pill toolbar, search any app by name or PID, sort the process table, drill into a group, or end a whole group / process tree (with confirmation).

<p align="center"><img src="docs/screenshots/network-ranking.png" width="55%" alt="network page with per-process traffic ranking"></p>

Per-module rankings show **who is actually responsible**: per-process disk read/write, per-process network traffic (read via the system `nettop` tool — no public API exists), and battery energy impact.

### Disk, the APFS way

Container-level capacity, per-volume breakdown, purgeable space, local APFS snapshots — same semantics Finder uses, not a naive `statfs`.

### 30-day history

Every metric lands in a local SQLite database (GRDB). Review system load, CPU, memory, network, and disk over the last hour, 24 hours, 7 days, or 30 days.

<p align="center"><img src="docs/screenshots/history.png" width="55%" alt="history charts"></p>

### Attribution engine (the fun part)

Three layers, in order:

1. **Bundle attribution** — processes group under their app, helpers and XPC services included;
2. **Parent-chain walk** — with a birth registry so the chain survives intermediate processes dying;
3. **Project roots** — configured in Settings, matched by cwd/argv; a git worktree shows up as `project @ worktree`.

Whatever is left is an **orphan process**, highlighted orange — it is usually exactly the thing you were looking for.

### Alerts that don't nag

Five built-in presets — sustained system load, an app group burning CPU, a new group eating memory, free disk below 20 GB, and *idle dev servers*. Hysteresis and per-kind cooldowns keep them from storming you. Click a notification to jump straight to the main window; if notifications were denied, Pulse offers a one-click path to System Settings.

The dev-server finder recognizes vite / next dev / webpack-dev-server / tsc · vitest · jest · pytest watch / django runserver / bun dev / cargo watch from argv, probes their ports, and flags the ones idle for ~10 minutes. Inventory only — Pulse never kills anything for you.

### Settings

Launch at login, menu bar slots, project roots, file logs (`~/.Pulse/logs`, rotated), and a one-copy diagnostic report for bug reports.

<p align="center"><img src="docs/screenshots/settings.png" width="60%" alt="settings window"></p>

## Resource budget

Built for a machine you actually work on:

- Userland APIs only — `proc_listallpids` / `proc_pidinfo` / `host_processor_info` / `host_statistics64` — **no root**, no kernel extensions;
- Adaptive sampling: 1 s while the popover is open, 5 s otherwise;
- Idle cost ≈ 1% of one core, measured;
- Logs to `~/.Pulse/logs` with rotation.

## Build from source

Requirements: macOS 26+, Xcode 26 with the Swift 6 toolchain, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/GaoZimeng0425/pulse.git
cd pulse
xcodegen generate        # generates Pulse.xcodeproj from project.yml — never edit the pbxproj by hand
open Pulse.xcodeproj     # then Run (⌘R)
```

Optional but recommended for development:

```bash
sh .githooks/install.sh  # pre-commit gate: incremental build on staged Swift changes
sh scripts/check.sh      # full check: build + all 535 unit tests
sh scripts/test.sh --only SomeTests  # run a single suite
```

## Roadmap

By permission tier, root-free first:

- **P2** — GPU / Neural Engine / temperature & fans / sound / Bluetooth / container cards (all root-free)
- **P3** — privileged helper (per-app energy / GPU / network attribution) + MCP server, so an agent can just ask `why_cpu_high()`

## Acknowledgements

- **UI & metric-semantics baseline**: [Vitals](https://vitalsmac.com) (closed-source — behavior alignment only, its code was never touched)
- **Algorithm references (MIT, ports noted in file headers)**: [exelban/stats](https://github.com/exelban/stats) (GPU/ANE/SMC/network/battery), [henrydennis/petal](https://github.com/henrydennis/petal) (APFS container capacity), [jithin-sabu/purge-app](https://github.com/jithin-sabu/purge-app) (artifact catalogs & activity heuristics)
- **Ideas only, no code**: [tw93/Mole](https://github.com/tw93/Mole) (GPL-3.0)
