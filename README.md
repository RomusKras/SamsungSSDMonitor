<div align="center">

# 🧊 SSDMonitor

### Samsung NVMe SMART telemetry, right in the macOS menu bar

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-Toolchain-F05138?style=for-the-badge&logo=swift&logoColor=white)](#build-and-run)
[![Thunderbolt](https://img.shields.io/badge/Thunderbolt%2FUSB4-40%20Gbps-0A84FF?style=for-the-badge&logo=usb&logoColor=white)](#why-this-works-at-all)
[![smartmontools](https://img.shields.io/badge/smartctl-no%20sudo-2ECC71?style=for-the-badge)](#requirements)
[![License](https://img.shields.io/badge/License-MIT-6E7681?style=for-the-badge)](LICENSE)

**English** · [Русский](README.ru.md)

<br>

<img src="docs/screenshot.png" width="380" alt="SSDMonitor dropdown menu in the macOS menu bar showing Samsung SSD 9100 PRO metrics">

</div>

<br>

A macOS menu bar widget for monitoring a Samsung SSD 9100 PRO (or any other NVMe drive) connected through a **Thunderbolt/USB4 enclosure**. It shows temperature, wear, TBW and the rest of the SMART telemetry — the things Samsung Magician won't give you, since it has no macOS build at all and the Windows one can't see drives behind USB/TB bridges.

> [!NOTE]
> The widget's interface is currently Russian-only. Menu labels are quoted below with an English gloss where it matters.

---

## Why this works at all

Samsung Magician and most SMART tools can't see a drive in an external enclosure, because a typical USB enclosure is a **USB→NVMe bridge that translates the protocol** (JMicron/ASMedia/Realtek chips) and often won't pass low-level NVMe commands through.

The enclosure this widget was written for connects over **Thunderbolt/USB4 (40 Gbps)** and **tunnels real PCIe** — macOS sees the drive as an ordinary `Protocol: PCI-Express` NVMe device (`system_profiler SPNVMeDataType`), with no translation in the way. That's why `smartctl` reads the full SMART/Health log with no workarounds and **without sudo**.

If your enclosure is a plain USB-SATA/USB-NVMe bridge rather than Thunderbolt/USB4, odds are nothing will work: `smartctl --scan-open` either won't list the device at all, or will list it with no access to the SMART logs.

## What it shows

- Model, serial number, firmware version
- Health / wear (`percentage_used`, `available_spare` threshold)
- Temperature (current + both sensors + warning/critical thresholds), with the icon turning orange or red as it approaches them
- Written / read in TB (derived from `data_units_*` per the NVMe spec: 1 unit = 512,000 bytes)
- Power-on time in hours and days, power cycle count, unsafe shutdowns
- Media errors and error log entries
- Critical warnings (`critical_warning` bitfield)
- Time of the last refresh

## What it can't (and won't) do

All of these need proprietary vendor-specific NVMe commands that only Samsung's official driver knows. I didn't reverse-engineer them — too easy to brick the drive:

- Firmware updates
- Secure Erase
- Over-Provisioning
- RAPID mode
- Benchmarking (this one is perfectly doable as a separate feature — it's not a protocol limitation, just not built)

## Requirements

- macOS 13+
- Swift toolchain (Xcode Command Line Tools)
- [smartmontools](https://www.smartmontools.org/) — `brew install smartmontools`
  - The binary is looked up at `/opt/homebrew/bin/smartctl` and `/usr/local/bin/smartctl`

## Build and run

```bash
git clone https://github.com/RomusKras/SamsungSSDMonitor.git
cd SamsungSSDMonitor
swift build -c release
./.build/release/SSDMonitor        # foreground run, for debugging
```

The widget is an accessory app (`NSApp.setActivationPolicy(.accessory)`): no Dock icon, menu bar only.

## Autostart via LaunchAgent

Run this **from the repo root** — `$PWD` expands so the binary path is filled in for you:

```bash
cat > ~/Library/LaunchAgents/com.romankrasovskij.ssdmonitor.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>com.romankrasovskij.ssdmonitor</string>
    <key>ProgramArguments</key>  <array><string>$PWD/.build/release/SSDMonitor</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>ProcessType</key>       <string>Interactive</string>
    <key>KeepAlive</key>         <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key>   <string>/tmp/ssdmonitor.out.log</string>
    <key>StandardErrorPath</key> <string>/tmp/ssdmonitor.err.log</string>
</dict>
</plist>
PLIST
```

`KeepAlive.SuccessfulExit = false` means it restarts on a crash, but stays down when you quit it from the menu yourself.

```bash
# load / enable autostart
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.romankrasovskij.ssdmonitor.plist

# restart after a rebuild (kill + restart in one command)
launchctl kickstart -k gui/$(id -u)/com.romankrasovskij.ssdmonitor

# check status (state = running / not running, PID, etc.)
launchctl print gui/$(id -u)/com.romankrasovskij.ssdmonitor

# unload completely (disable autostart)
launchctl bootout gui/$(id -u)/com.romankrasovskij.ssdmonitor
```

Daemon logs: `/tmp/ssdmonitor.out.log`, `/tmp/ssdmonitor.err.log`.

> [!IMPORTANT]
> `swift build` simply overwrites the binary at the same path — the LaunchAgent only picks up the new version after `kickstart -k` (or a logout/login). It will not restart itself when the file changes.

### Development loop

```bash
# edit Sources/SSDMonitor/main.swift
swift build -c release
launchctl kickstart -k gui/$(id -u)/com.romankrasovskij.ssdmonitor
```

## Refresh interval

Set it right in the widget menu: **«Интервал обновления»** (refresh interval) → 10 s / 30 s / 1 min / 2 min / 5 min, with the active one check-marked. Picking a value:

1. restarts the internal timer immediately,
2. fires a `refresh()` immediately,
3. persists to `UserDefaults` and survives a restart — under the *process* domain, since the binary has no bundle id, so **not** `com.romankrasovskij.ssdmonitor` (see *Known quirks* below).

The default is 30 seconds, until you change it from the menu at least once.

```bash
# read the stored interval in seconds, if it was ever set
defaults read SSDMonitor refreshInterval

# reset to the default (30 s)
defaults delete SSDMonitor refreshInterval
```

## Drive auto-detection

The `IOService:...` path to the NVMe controller is **never hardcoded** and never cached between refreshes — every timer tick calls `smartctl --scan-open -j` again, walks all the NVMe devices it finds, and takes the first one whose `model_name` contains `samsung` (case-insensitive). Which means:

- unplug/replug of the enclosure is picked up automatically, with no widget restart;
- if several Samsung NVMe drives are attached at once (a built-in Samsung SSD plus an external one, say), the first one in scan order wins — not necessarily the one you meant. With that setup you'll want to hardcode a specific path or filter by serial in `Smartctl.findSamsungReport()` ([main.swift](Sources/SSDMonitor/main.swift)).

## What happens if you yank the drive

The widget survives it without crashing. Blow by blow:

1. Every refresh cycle calls `smartctl --scan-open -j` from scratch — the device path is never cached between ticks (see [Drive auto-detection](#drive-auto-detection)). Pull the drive and it simply drops out of the scan.
2. `findSamsungReport()` finds no model with `samsung` in the name → `update(with: nil)` → `showError(...)`.
3. The menu bar icon switches to the warning variant (`externaldrive.trianglebadge.exclamationmark`) and the title goes red — **«нет диска»** (no drive) instead of a temperature.
4. The menu keeps a **«Последний раз виден: HH:MM:SS»** (last seen) line — the time of the last successful poll, so it's clear the data isn't merely stale, the drive is genuinely gone.
5. Plug it back in and the next timer tick — or a manual **«Обновить сейчас»** (refresh now) — picks it up again. No restart needed.

Guards against the `smartctl` process itself wedging, in case the drive goes away mid NVMe command:

- every `smartctl` call carries a 5 s watchdog (`Smartctl.run(timeout:)`) — a process that hasn't exited gets killed (`process.terminate()`) and the refresh falls back to "not found" instead of hanging forever;
- `refresh()` ignores a new timer tick while the previous cycle is still running (the `isRefreshing` flag) — so wedged background `smartctl` processes can't pile up, even if several ticks in a row go wrong.

> [!WARNING]
> **Not tested physically:** actually yanking the cable in the middle of an NVMe command. The logic was simulated with a deliberately nonexistent `IOService:...` path (`smartctl` fails instantly there, ~0.03 s, `exit_status: 2`, `No such file or directory`) — enough for ordinary unplug/replug, but not a 100% guarantee against exotic races down in the enclosure's driver. I wasn't willing to yank the live drive: this project's own working directory sits on it (`/Volumes/Samsung9100Pro/...`), so cutting it off would take down the files open in the IDE along with the running shell session.

<details>
<summary><b>Manual diagnostics</b></summary>

<br>

```bash
# list every visible NVMe controller
smartctl --scan-open --json

# full SMART dump for one device (path taken from --scan-open)
smartctl -a -j "IOService:/...path.../IONVMeBlockStorageDevice@1" -d nvme

# quick check at the macOS level, no smartctl involved
system_profiler SPNVMeDataType

# confirm the enclosure tunnels PCIe instead of translating the protocol
system_profiler SPThunderboltDataType
diskutil info diskN | grep Protocol   # should say "PCI-Express", not "USB"
```

If `smartctl --scan-open` can't find the external drive, the problem isn't this widget — it's the enclosure or the connection (see [Why this works at all](#why-this-works-at-all)).

</details>

<details>
<summary><b>Known quirks and gotchas</b></summary>

<br>

- **sudo is only needed** if your particular enclosure + chip combination demands it — for a Thunderbolt/USB4 tunnel it usually doesn't (verified).
- The app is **unsigned and not under App Translocation** — Gatekeeper shouldn't complain, since the binary is built locally rather than downloaded.
- `UserDefaults.standard` in an unbundled binary writes to `~/Library/Preferences/SSDMonitor.plist`, named after the process — not the reverse-DNS id from `Package.swift` or the LaunchAgent label. Easy to mix up when debugging via `defaults read`.
- Under some Accessibility automation tools the status bar item may be reported as belonging to "Control Center". This doesn't affect ordinary mouse clicks in a real session — it only shows up in programmatic UI-driven testing of unsigned processes.

</details>

## License

[MIT](LICENSE) — do whatever you want with it, just keep the copyright notice.
