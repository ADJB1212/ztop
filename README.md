# ztop

![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)
![Zig](https://img.shields.io/badge/Zig-0.16%2B-orange)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

<p align="center">
    <img src="./assets/screenshot.png" width="800"/>
</p>

`ztop` is a terminal system monitor for macOS and Linux. It gives you a fast, keyboard-driven view of CPU load, memory pressure, disk and network throughput, hardware sensors, GPU activity, battery status, and the busiest processes — without leaving the shell.

Built for people who want a focused dashboard in the terminal: quick enough to keep open all day, detailed enough to answer "what is using this machine right now?", and interactive enough to act on what you find.

## Features

- Four focused views: `Main`, `I/O`, `Sensors`, and `Network`
- Live process table with sorting, filtering, tree view, and per-thread drill-down
- CPU topology map grouping logical threads by physical core, cache domain, and heterogeneous cluster
- GPU monitoring on supported hardware:
  - NVIDIA via NVML when `libnvidia-ml` is present
  - AMD via DRM/sysfs counters exposed by `amdgpu`
  - Apple Silicon via IORegistry accelerator performance statistics
- Dynamic process-table columns with an in-app picker (PID, PPID, state, CPU, memory, threads, disk rates, wakeups/churn)
- Mouse support for tab switching, list navigation, and scrolling
- Timeline scrubbing with incident bookmarks and before/after diff: pause live view, scrub through recent history, drop markers to jump back to interesting moments, and compare two captured snapshots side-by-side
- **Why is this busy?** (`w`) — ranked explanation view showing which processes are driving the current CPU, memory, disk, network, or wakeup-churn spike, with delta indicators against a 5-tick baseline
- **Wakeup attribution** (`u` sort + optional `wakeups` column) — surfaces timer wakeups and scheduler churn (`W` wakeups/sec, `C` context-switches/sec), including low-CPU/high-churn workloads
- **Resource causality graph** (`g`) — per-process view linking a selected process to its child tree, open network connections, and a resource summary
- **Pressure root-cause hints** (`P`) — automatic detection of pathological patterns: swap storms, runaway log writers, reconnect loops, file descriptor pressure, memory leak suspects, CPU runaways, thermal throttle risk, and cache starvation
- Built-in process actions: `SIGTERM`, `SIGKILL`, `:killall`, `:show zombie`, `:search`
- Process follow mode (`l`): lock the view to a selected process as it moves through the list
- Responsive layout for narrow terminals
- Configurable refresh interval, default sort, theme, and per-color overrides
- Themes: `default`, `default_dark`, `default_light`, `gruvbox`, `nord`, `solarized`, `catppuccin`, `palenight`, `colorblind`

## Installation

### Homebrew (macOS & Linux)

```bash
brew tap ADJB1212/ztop
brew install ztop
```

### Build from Source

**Requirements:** Zig `0.16.0` or newer, a POSIX terminal.

```bash
git clone https://github.com/ADJB1212/ztop.git
cd ztop
zig build -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/ztop`. Copy it anywhere on your `PATH`:

```bash
cp zig-out/bin/ztop ~/.local/bin/
```

To run directly without installing:

```bash
zig build run
```

To run the test suite:

```bash
zig build test
```

## Usage

```
ztop [--version] [--help]
```

### Key Bindings

| Key                     | Action                                                                    |
| ----------------------- | ------------------------------------------------------------------------- |
| `1`, `2`, `3`, `4`      | Switch to `Main`, `I/O`, `Sensors`, `Network`                             |
| `j` / `k` or arrow keys | Move through the process list                                             |
| `Enter`                 | Drill into threads of the selected process                                |
| `Esc`                   | Return from any view; clear follow, filter, status, or zombie view        |
| `c`, `m`, `p`, `n`, `u` | Sort by CPU, memory, PID, name, or wakeups/churn                          |
| `C`                     | Toggle process-table columns for the current view                         |
| `v`                     | Toggle tree view (process hierarchy)                                      |
| `/`                     | Filter processes by name or PID                                           |
| `:`                     | Open command mode                                                         |
| `l`                     | Follow selected process (lock view to it as it moves)                     |
| `g`                     | Resource causality graph for selected process (children + connections)    |
| `w`                     | Why is this busy? — ranked spike explanation with process deltas          |
| `P`                     | Pressure root-cause hints — detect swap storms, log writers, reconnect loops, and more |
| `T`                     | Toggle timeline scrubbing mode (requires enough collected history)        |
| `←` / `→`               | While scrubbing: move older/newer by one snapshot                         |
| `[` / `]`               | While scrubbing: jump older/newer by 10 snapshots                         |
| `b`                     | While scrubbing: drop a bookmark at the current position                  |
| `B`                     | While scrubbing: remove the nearest bookmark                              |
| `{` / `}`               | While scrubbing: jump to previous/next bookmark                           |
| `d`                     | While scrubbing: toggle diff view (set anchor, then navigate to compare)  |
| `t`                     | Send `SIGTERM` to the selected process                                    |
| `K`                     | Send `SIGKILL` to the selected process                                    |
| `?`                     | Open help overlay                                                         |
| `q`                     | Quit                                                                      |

While scrubbing is active, destructive process actions and view-mutating actions are disabled until you exit scrubbing.
Press `Esc` or `T` to leave scrubbing and return to live view.

Bookmarks persist for the session (up to 10). They appear as `▼` markers on the timeline bar. Use `b` to mark a moment of interest, `{`/`}` to hop between them, and `B` to remove the one nearest the cursor.

Press `d` while scrubbing to set a diff anchor at the current position. Then navigate to another moment — the view changes to a before/after comparison showing CPU, memory, disk, network, temperature deltas and the processes that changed the most. The anchor appears as `◆` on the timeline bar. Press `d` or `Esc` to exit the diff view.

### Command Mode

Press `:` to open command mode. Available commands:

```
:show zombie          Show zombie processes and jump to their parent
:killall <name>       Send SIGTERM to all processes matching <name>
:search <term>        Filter the process list by name or PID
:quit                 Quit ztop
```

## Diagnostic Views

### Why Is This Busy? (`w`)

Press `w` to open a ranked explanation of what is driving the current load. The view detects which resource is spiking (CPU, memory, disk, network, or wakeup churn), shows current metrics with delta indicators relative to a 5-tick baseline, and lists the top contributing processes sorted by their share of the spike. Wakeup mode is especially useful when CPU% is modest but wakeups/context switches are high. Works in live mode and in timeline scrubbing mode — when scrubbing, the view reflects the state at the current scrub position and highlights the nearest event type.

### Resource Causality Graph (`g`)

Press `g` with a process selected to open a causality view for that process. Shows:

- All child processes with their CPU and memory usage
- Active network connections (protocol, address, TCP state)
- A resource summary with CPU and memory meters, thread count, disk I/O rates, and the full launch command

### Pressure Root-Cause Hints (`P`)

Press `P` to surface automatically detected pathological patterns from current system state. Each hint includes a severity level (`!!` critical, `!` warning), a description, and the most likely culprit process where applicable.

Patterns detected:

| Pattern | Trigger |
| ------- | ------- |
| Swap storm | Swap > 15% used and growing over the last 30 snapshots |
| Swap pressure | Swap > 15% used (stable) |
| Runaway log writer | Single process > 8 MB/s writes with a log-related name, or > 40% of total disk writes |
| Disk write storm | Single process > 8 MB/s writes and > 40% of total disk writes |
| Reconnect loop | Process with > 15 TIME\_WAIT or CLOSE\_WAIT connections |
| FD pressure risk | Process with > 400 threads (proxy for high file descriptor usage) |
| Memory leak suspect | Process memory grew > 3pp over ~60 seconds while system memory > 50% |
| CPU runaway | Single process > 85% CPU while system total > 70% |
| Thermal throttle risk | CPU temperature ≥ 85 °C |
| Cache starvation | Page cache < 5% of RAM while memory pressure > 80% |

Press `P` or `Esc` to close.

## Configuration

`ztop` reads configuration from `$XDG_CONFIG_HOME/ztop.cfg` or `~/.config/ztop.cfg` when present.

Example configuration file:

```ini
theme = palenight
default_sort = cpu
default_tab = main
default_tree_view = false
show_help_on_startup = false
update_interval_ms = 500
process_columns = pid,cpu,mem,threads,state,wakeups
io_process_columns = pid,disk_read,disk_write,ppid
color.tab_active = 141
```

### Configuration Reference

| Key                    | Values                                                                                                                           |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `theme`                | `default`, `default_dark`, `default_light`, `gruvbox`, `nord`, `solarized`, `catppuccin`, `palenight`, `colorblind`              |
| `default_sort`         | `cpu`, `mem`, `pid`, `name`, `wakeups`                                                                                           |
| `default_tab`          | `main`, `io`, `sensors`, `network` (or `1`–`4`)                                                                                  |
| `default_tree_view`    | `true` / `false` (also `yes`/`no`, `1`/`0`)                                                                                      |
| `show_help_on_startup` | `true` / `false`                                                                                                                 |
| `update_interval_ms`   | Refresh interval in milliseconds                                                                                                 |
| `process_columns`      | Comma-separated list of `pid`, `ppid`, `state`, `cpu`, `mem`, `threads`, `disk_read`, `disk_write`, `wakeups` — or `none`, `default`, `all` |
| `io_process_columns`   | Same column names, applied to the I/O tab process table                                                                          |
| `color.<key>`          | Named ANSI color (e.g. `bright_cyan`) or xterm-256 index (e.g. `141`)                                                            |

The process name column is always visible. Press `C` inside `ztop` to toggle columns interactively.

## Platform Notes

**macOS:** Uses Mach APIs and `libproc` for process and system data. GPU data is read from IORegistry on Apple Silicon. No additional setup is required.

**Linux:** Uses `/proc`-based polling. NVIDIA GPU monitoring requires `libnvidia-ml` to be present at runtime. AMD GPU data is read from `amdgpu` sysfs counters.

## Contributing

Bug reports and pull requests are welcome. Please open an issue before starting significant work so the approach can be discussed first.

## License

`ztop` is released under the [GNU General Public License v3.0](LICENSE).
