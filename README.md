# USB Auto-Copy System v4.1 — Complete Technical Documentation & User Guide

A silent, fully automated, bidirectional document backup and offloading utility for Windows. The system runs invisibly in Session 0 under `SYSTEM` without console windows, taskbar icons, or pop-ups.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Key Features](#2-key-features)
3. [System Architecture & File Locations](#3-system-architecture--file-locations)
4. [Operational Modes](#4-operational-modes)
   - [Mode 1: Standard USB Auto-Backup (USB -> PC)](#mode-1-standard-usb-auto-backup-usb---pc)
   - [Mode 2: Target Drive Offloading (PC -> USB)](#mode-2-target-drive-offloading-pc---usb)
5. [Index, Deduplication & Safe Atomic Copy](#5-index-deduplication--safe-atomic-copy)
6. [Installation, Maintenance & Uninstallation](#6-installation-maintenance--uninstallation)
7. [Log File Format & Audit Trail](#7-log-file-format--audit-trail)
8. [Frequently Asked Questions (FAQ)](#8-frequently-asked-questions-faq)
9. [Disclaimer](#9-disclaimer)

---

## 1. System Overview

The **USB Auto-Copy System** automatically captures document files from inserted USB flash drives, SD cards, and external USB HDDs/SSDs. Once installed, it runs as a high-privileged Windows Scheduled Task (`SYSTEM` in Session 0), starting immediately upon installation and automatically on user logon.

It supports two automatic workflows based on the inserted drive:
1. **Ingestion (Source USB -> PC):** Safely backs up document files from connected USB drives to local storage without duplicating already-indexed files.
2. **Extraction (PC -> Target USB):** Safely moves collected documents from the PC onto any designated "Target" USB drive (identified by a `.syscopy_target` marker file) and cleans up empty directories.

---

## 2. Key Features

- **Native Session-0 Stealth (No VBS Wrapper):** Scheduled directly as `SYSTEM` via `powershell.exe -WindowStyle Hidden` in Session 0, eliminating console flashes and reducing AV false positives.
- **Global Single-Instance Mutex:** Uses `Global\USBAutoCopyMonitorMutexV4` with `AbandonedMutexException` recovery to prevent duplicate instances across sessions.
- **Broad USB Support & Leak-Free Detection:** Uses `[System.IO.DriveInfo]` to detect drive topology changes and queries CIM (`Get-CimInstance`) only when drives change—supporting both removable flash drives (`DriveType=2`) and external USB HDDs/SSDs (`InterfaceType='USB'`), while skipping empty card readers and never touching the OS drive.
- **Exact Single-Pass Scanning:** Walks each drive once using an exact extension `HashSet` (`.pdf`, `.pptx`, `.ppt`, `.docx`, `.doc`, `.xlsx`, `.xls`), avoiding Windows' 8.3 wildcard bug (e.g., `*.doc` matching `.docx`/`.docm`), skipping Microsoft Office temp lock files (`~$*`), NTFS junctions/symlinks, `$RECYCLE.BIN`, `System Volume Information`, and the USB's own `docs\` directory.
- **Long-Path Support (`\\?\`):** Automatically switches to Windows extended-length paths for deeply nested paths exceeding 260 characters.
- **Safe Atomic Copy (`.tmp` + `.bak`):** Used for **both** Source USB -> PC and PC -> Target USB transfers; verifies source stability and exact byte length before atomically swapping into place (with automatic rollback if replacement fails).
- **Resilient Maintenance:** Automatic periodic log rotation (2,000 lines), atomic index compaction (10,000 entries), and per-file exponential error backoff to prevent log spam.
- **Hardened Permissions:** `SYSCOPY` is hidden and ACL-restricted to `SYSTEM` and `Administrators` only.

---

## 3. System Architecture & File Locations

All components are stored in `C:\ProgramData\USBAutoCopy` (safe across Windows Feature Updates):

- **Storage Root:** `C:\ProgramData\USBAutoCopy\`
- **Collected Documents:** `C:\ProgramData\USBAutoCopy\docs\`
- **System Directory:** `C:\ProgramData\USBAutoCopy\SYSCOPY\` *(Hidden, restricted to `SYSTEM` & `Administrators`)*
- **Monitor Script:** `C:\ProgramData\USBAutoCopy\SYSCOPY\usb_monitor.ps1`
- **Index File:** `C:\ProgramData\USBAutoCopy\SYSCOPY\systemcopydocs.index`
- **Log File:** `C:\ProgramData\USBAutoCopy\SYSCOPY\autocopy_log.txt`
- **Scheduled Task:** `USB_AutoCopy_Silent_Monitor` (`SYSTEM`, `RunLevel Highest`, `MultipleInstances IgnoreNew`, auto-restart on failure)

---

## 4. Operational Modes

Target extensions (exact match, case-insensitive): `.pdf`, `.pptx`, `.ppt`, `.docx`, `.doc`, `.xlsx`, `.xls`.

### Mode 1: Standard USB Auto-Backup (USB -> PC)
**Trigger:** Any ready USB drive without a `.syscopy_target` file in its root.
**Action:**
1. Resolves a consistent folder under `C:\ProgramData\USBAutoCopy\docs\` using the drive's hardware `VolumeSerialNumber` (`<Serial>_<Label>`). If the drive's label is later renamed, the existing `<Serial>_*` folder is reused.
2. Walks the USB once, excluding `<Drive>:\docs\` (with exact trailing-backslash matching so `docs_2026\` or `docs.pdf` are **not** excluded), `~$*` Office lock files, symlinks/junctions, and system folders.
3. Checks each file against the cached in-memory index (`serial|relPath|size|2s-mtime-bucket`). Already-indexed versions are skipped immediately.
4. Copies new or updated files via `Safe-CopyFile` (`.tmp` + integrity verification + atomic swap), creating folders lazily only when needed.
5. Stops immediately if the drive is unplugged mid-scan.

### Mode 2: Target Drive Offloading (PC -> USB)
**Trigger:** Any ready USB drive containing a file named `.syscopy_target` in its root directory (no hardcoded serial numbers).
**Action:**
1. Automatically sets the `Hidden` attribute on `.syscopy_target`.
2. Scans `C:\ProgramData\USBAutoCopy\docs\` for collected documents.
3. Compares each file against `<TargetUSB>:\docs\<relPath>` using file size and a 2-second timestamp tolerance (for FAT32 compatibility):
   - If missing on Target USB, or different size, or PC copy is >2 seconds newer: transfers using `Safe-CopyFile` and deletes the PC original **only after** verified success.
   - If the Target USB already holds an identical or newer copy: removes the redundant PC copy.
4. Prunes empty directories bottom-up (deepest first) so nested folder trees are completely cleaned.

---

## 5. Index, Deduplication & Safe Atomic Copy

- **Index Key Format:** `<Serial>|<RelativePath>|<SizeBytes>|<2sUtcMtimeBucket>`
  - Distinct USB drives or subfolders holding identical files are tracked independently.
  - Updated files produce a new key and replace the older backup atomically.
  - 2-second time buckets avoid false mismatches on FAT32 drives.
  - Cached in memory (reloaded only when changed on disk) and atomically compacted to at most 10,000 entries.
- **Safe Atomic Copy (`Safe-CopyFile`):**
  1. Copies source to `<dest>.tmp` and verifies source size/mtime did not change mid-copy and `.tmp` size matches source.
  2. Atomically swaps `.tmp` into `<dest>` using `[System.IO.File]::Replace` (with a `.bak` rollback fallback for FAT32/exFAT), so an existing backup is never lost if a move fails.
  3. Cleans up any leftover `.tmp` or `.bak` files on startup.

---

## 6. Installation, Maintenance & Uninstallation

`INSTALL_USB_AutoCopy_v4.bat` is a self-contained, self-elevating installer/updater/uninstaller.

### Installation
1. Double-click `INSTALL_USB_AutoCopy_v4.bat`.
2. Approve the UAC Administrator prompt.
3. The script creates `C:\ProgramData\USBAutoCopy`, hardens `SYSCOPY` permissions, writes `usb_monitor.ps1`, registers `USB_AutoCopy_Silent_Monitor`, and starts it via Task Scheduler.
4. A confirmation dialog appears when ready.

### Update & Uninstallation
1. Double-click `INSTALL_USB_AutoCopy_v4.bat` again while already installed.
2. Choose an action before any files are modified:
   - **Update:** Stops the scheduled task and waits for monitor processes to exit, preserves your `docs\` and index (migrating any legacy index from `C:\Windows\Downloaded Win Docs\SYSCOPY`), and installs the latest script.
   - **Uninstall:** Stops the task and processes, unregisters the Scheduled Task, removes `SYSCOPY`, and verifies deletion. Your collected files in `C:\ProgramData\USBAutoCopy\docs` remain untouched.
   - **Cancel:** Exits cleanly without touching the filesystem.

---

## 7. Log File Format & Audit Trail

All activity and errors are logged to `C:\ProgramData\USBAutoCopy\SYSCOPY\autocopy_log.txt` (automatically rotated to the last 2,000 lines both at startup and periodically during runtime):

```text
2026-11-24 09:10:05 | USB Auto-Copy Monitor v4.1 STARTED
2026-11-24 09:11:12 | SOURCE | WORK_DRIVE (3A9F12B0) | 4 NEW copied, 12 skipped (indexed), 0 errors
2026-11-24 09:15:22 | TARGET | MY_TARGET (702968E6) | 12 moved, 0 already-synced cleaned, 0 errors
```

If a file fails to copy or move (e.g., locked or corrupt), per-file exponential backoff (30s up to 10m) prevents continuous log spam while retrying automatically later.

---

## 8. Frequently Asked Questions (FAQ)

**Q: Do I need to copy the `.bat` file to the PC before running it?**
A: No. You can run `INSTALL_USB_AutoCopy_v4.bat` from any folder or USB drive (including paths with spaces, parentheses, or apostrophes). Once the confirmation dialog appears, the USB drive can be removed.

**Q: Does it work with external USB SSDs/HDDs, not just flash drives?**
A: Yes. It detects both `DriveType = 2` removable drives and `InterfaceType = 'USB'` external fixed drives while strictly excluding the Windows system drive.

**Q: Will the 5-second polling drain battery or leak memory?**
A: No. Each poll checks `[System.IO.DriveInfo]::GetDrives()` and only queries CIM when drives are added, removed, or renamed. The index stays cached in memory, avoiding repeated disk reads.

**Q: Why is there no VBS launcher anymore?**
A: Running the Scheduled Task directly as `SYSTEM` executes in Windows Session 0 (which has no interactive desktop), so `powershell.exe -WindowStyle Hidden` is completely invisible without needing `wscript.exe`.

---

## 9. Disclaimer

This utility is provided for **educational and authorized administrative use only**. Ensure you have explicit consent and authorization before copying data from any storage device. The creator assumes no liability for unauthorized access, misuse, or data loss.
