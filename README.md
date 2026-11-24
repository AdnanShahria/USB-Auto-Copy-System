# USB Monitor v4.2 — Technical Documentation & User Guide

An automated, bidirectional USB document backup and offloading utility for Windows. Runs quietly in the background and shows brief 1-second status toasts (`Starting...` → `OK`) when a Target USB is connected.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Key Features](#2-key-features)
3. [File Locations](#3-file-locations)
4. [Operational Modes](#4-operational-modes)
5. [Target USB & Ignore Identification](#5-target-usb--ignore-identification)
6. [Index & Safe Atomic Copy](#6-index--safe-atomic-copy)
7. [Installation, Adding Target USBs & Uninstallation](#7-installation-adding-target-usbs--uninstallation)
8. [Log File Format](#8-log-file-format)
9. [Disclaimer](#9-disclaimer)

---

## 1. Overview

**USB** monitors connected USB flash drives, SD cards, and external USB HDDs/SSDs and handles two workflows automatically:
1. **Source USB → PC:** Copies new or updated document files (`.pdf`, `.pptx`, `.ppt`, `.docx`, `.doc`, `.xlsx`, `.xls`) into local storage without duplicating previously indexed files.
2. **PC → Target USB:** Moves collected documents onto your designated Target USB, shows a 1-second `Starting...` toast on connect and a 1-second `OK` toast on completion, and prunes empty folders bottom-up.

---

## 2. Key Features

- **1-Second Target GUI Toasts:** Displays a non-intrusive bottom-right `Starting...` toast (1s) when a Target USB is plugged in, then `OK` (1s) when finished, then stays quiet until unplugged and reconnected (or until new files arrive).
- **Flexible Target Identification (No Marker File Required):** Recognize Target USBs via Hardware Disk Serial, Volume Serial, `LABEL:<Name>` in `targets.txt`, **or** a `.syscopy_target` file in the USB root.
- **Ignore Support:** Skip personal drives completely via `ignore.txt` or a `.syscopy_ignore` marker file.
- **Global Single-Instance Mutex:** Uses `Global\USBMonitorMutexV4` with `AbandonedMutexException` recovery.
- **Broad USB Support & Leak-Free Detection:** Uses `[System.IO.DriveInfo]` change detection + on-demand CIM/`Get-Disk` lookup (supports both removable drives and external USB HDDs/SSDs, skips empty card readers, excludes the Windows system drive).
- **Exact Single-Pass Scanning + Long-Path Support (`\\?\`):** Exact extension `HashSet` (fixes Win32 `*.doc` matching `.docx`/`.docm`), skips Office `~$*` temp files, junctions/symlinks, `$RECYCLE.BIN`, and `System Volume Information` (while scanning all other folders, including `docs\` on non-Target USBs).
- **Safe Atomic Copy (`.tmp` + `.bak`):** Used for both Source → PC and PC → Target transfers, with integrity verification and rollback protection.
- **Resilient Maintenance:** Periodic atomic log rotation (2,000 lines), atomic index compaction (10,000 entries), and per-file exponential error backoff.

---

## 3. File Locations

All files live under `C:\ProgramData\USB` *(note: `C:\ProgramData` is hidden by default in Windows Explorer)*:

- **Collected Documents:** `C:\ProgramData\USB\docs\`
- **System Directory (Hidden, Admin/SYSTEM ACL):** `C:\ProgramData\USB\SYSCOPY\`
  - Monitor Script: `C:\ProgramData\USB\SYSCOPY\usb_monitor.ps1`
  - Silent Launcher: `C:\ProgramData\USB\SYSCOPY\usb_launcher.vbs`
  - Index File: `C:\ProgramData\USB\SYSCOPY\systemcopydocs.index`
  - Target Allowlist: `C:\ProgramData\USB\SYSCOPY\targets.txt`
  - Ignore Allowlist: `C:\ProgramData\USB\SYSCOPY\ignore.txt`
  - Log File: `C:\ProgramData\USB\SYSCOPY\usb_log.txt`
- **Scheduled Task:** `USB_Monitor` (Interactive elevated logon task, `MultipleInstances IgnoreNew`, auto-restart on failure)

---

## 4. Operational Modes

### Source Mode (USB → PC)
- Resolves a consistent folder under `C:\ProgramData\USB\docs\<Serial>_<Label>` (reuses existing `<Serial>_*` folder if the drive is renamed).
- Checks the cached in-memory index (`serial|relPath|size|2s-mtime-bucket`) and copies only new or modified documents via `Safe-CopyFile`.

### Target Mode (PC → USB)
- Shows a 1-second `Starting...` toast on initial plug-in.
- Transfers collected documents from `C:\ProgramData\USB\docs\` to `<TargetUSB>:\docs\` using `Safe-CopyFile`, deletes PC originals only after verified success (and cleans up already-synced copies), and removes empty directories bottom-up.
- Shows a 1-second `OK` toast when complete.

---

## 5. Target USB & Ignore Identification

A connected USB is checked in this order:
1. **Ignored (skipped completely):** Has `.syscopy_ignore` in root **OR** matches an entry in `C:\ProgramData\USB\SYSCOPY\ignore.txt`.
2. **Target USB (receives docs, never copied from):** Has `.syscopy_target` in root (auto-hidden) **OR** matches an entry in `C:\ProgramData\USB\SYSCOPY\targets.txt`:
   - **Hardware Disk Serial** (survives reformatting) — easiest to add via the installer's **Add Target USB** button.
   - **Volume Serial Number** (e.g., `702968E6`).
   - **Volume Label** using `LABEL:` prefix (e.g., `LABEL:MY_VAULT`).
3. **Source USB:** All other ready USB drives.

---

## 6. Index & Safe Atomic Copy

- **Index Key:** `<Serial>|<RelativePath>|<SizeBytes>|<2sUtcMtimeBucket>` — case-insensitive, cached in memory, atomically compacted to at most 10,000 entries.
- **Safe Copy:** Copies to `.tmp`, verifies source stability and exact byte count, then swaps atomically via `[System.IO.File]::Replace` (with `.bak` rollback fallback on FAT32/exFAT).

---

## 7. Installation, Adding Target USBs & Uninstallation

1. **Install:** Double-click `INSTALL_USB_AutoCopy_v4.bat` and accept the UAC prompt.
2. **Manage (Update / Add Target USB / Uninstall):** Double-click `INSTALL_USB_AutoCopy_v4.bat` again:
   - **Update:** Stops any running monitor/legacy tasks, migrates any legacy index, and installs the latest scripts.
   - **Add Target USB:** Detects currently plugged-in USB drives and registers your selected drive's Hardware/Volume serial into `targets.txt` (no marker file needed on the USB).
   - **Uninstall:** Stops processes, removes the scheduled task and `SYSCOPY`, and keeps `C:\ProgramData\USB\docs\` safe.

---

## 8. Log File Format

Logged to `C:\ProgramData\USB\SYSCOPY\usb_log.txt`:

```text
2026-11-24 16:50:05 | USB Monitor v4.2 STARTED
2026-11-24 16:51:12 | SOURCE | WORK_DRIVE (3A9F12B0) | 4 NEW copied, 12 skipped (indexed), 0 errors
2026-11-24 16:55:22 | TARGET | MY_TARGET (702968E6) | 12 moved, 0 already-synced cleaned, 0 errors
```

---

## 9. Disclaimer

Provided for **educational and authorized administrative use only**. Ensure you have explicit consent and authorization before copying data from any storage device.
