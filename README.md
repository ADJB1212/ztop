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
- Dynamic process-table columns with an in-app picker (PID, PPID, state, CPU, memory, threads, disk rates)
- Mouse support for tab switching, list navigation, and scrolling
- Built-in process actions: `SIGTERM`, `SIGKILL`, `:killall`, `:show zombie`, `:search`
- Responsive layout for narrow terminals
- Configurable refresh interval, default sort, theme, and per-color overrides
- Themes: `default`, `default_dark`, `default_light`, `gruvbox`, `nord`, `solarized`, `catppuccin`, `palenight`

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

| Key                     | Action                                                        |
| ----------------------- | ------------------------------------------------------------- |
| `1`, `2`, `3`, `4`      | Switch to `Main`, `I/O`, `Sensors`, `Network`                 |
| `j` / `k` or arrow keys | Move through the process list                                 |
| `Enter`                 | Drill into threads of the selected process                    |
| `Esc`                   | Return from thread view; clear filter, status, or zombie view |
| `c`, `m`, `p`, `n`      | Sort by CPU, memory, PID, or name                             |
| `C`                     | Toggle process-table columns for the current view             |
| `v`                     | Toggle tree view (process hierarchy)                          |
| `/`                     | Filter processes by name or PID                               |
| `:`                     | Open command mode                                             |
| `t`                     | Send `SIGTERM` to the selected process                        |
| `K`                     | Send `SIGKILL` to the selected process                        |
| `?`                     | Open help overlay                                             |
| `q`                     | Quit                                                          |

### Command Mode

Press `:` to open command mode. Available commands:

```
:show zombie          Show zombie processes and jump to their parent
:killall <name>       Send SIGTERM to all processes matching <name>
:search <term>        Filter the process list by name or PID
:quit                 Quit ztop
```

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
process_columns = pid,cpu,mem,threads,state
io_process_columns = pid,disk_read,disk_write,ppid
color.tab_active = 141
```

### Configuration Reference

| Key                    | Values                                                                                                                           |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `theme`                | `default`, `default_dark`, `default_light`, `gruvbox`, `nord`, `solarized`, `catppuccin`, `palenight`                            |
| `default_sort`         | `cpu`, `mem`, `pid`, `name`                                                                                                      |
| `default_tab`          | `main`, `io`, `sensors`, `network` (or `1`–`4`)                                                                                  |
| `default_tree_view`    | `true` / `false` (also `yes`/`no`, `1`/`0`)                                                                                      |
| `show_help_on_startup` | `true` / `false`                                                                                                                 |
| `update_interval_ms`   | Refresh interval in milliseconds                                                                                                 |
| `process_columns`      | Comma-separated list of `pid`, `ppid`, `state`, `cpu`, `mem`, `threads`, `disk_read`, `disk_write` — or `none`, `default`, `all` |
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
