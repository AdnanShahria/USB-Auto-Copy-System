# USB Auto-Copy System — Complete Technical Documentation & User Guide

A silent, fully automated, bidirectional file synchronization and backup utility for Windows. The system operates invisibly in the background without pop-ups, console windows, or user intervention.

---

## Table of Contents
1. [System Overview](#system-overview)
2. [Key Features](#key-features)
3. [System Architecture & File Locations](#system-architecture--file-locations)
4. [Operational Modes](#operational-modes)
   - [Mode 1: Standard USB Auto-Backup (USB → PC)](#mode-1-standard-usb-auto-backup-usb--pc)
   - [Mode 2: Special Pendrive Offloading / Reverse-Sync (PC → USB)](#mode-2-special-pendrive-offloading--reverse-sync-pc--usb)
5. [Installation, Maintenance & Uninstallation](#installation-maintenance--uninstallation)
6. [Under the Hood: Technical Mechanics](#under-the-hood-technical-mechanics)
7. [Supported File Extensions](#supported-file-extensions)
8. [Comprehensive FAQ & Edge-Case Solutions](#comprehensive-faq--edge-case-solutions)
9. [Log File Format & Audit Trail](#log-file-format--audit-trail)

---

## System Overview

The **USB Auto-Copy System** solves two primary workflow needs:
1. **Automatic PC Backup**: Quietly archives documents from any connected USB flash drive into a organized folder structure on the PC.
2. **Automated Pendrive Offloading**: Recognizes a designated "special" pendrive and automatically moves local documents from the PC onto the USB drive to clear PC disk space while keeping files updated.

Everything is managed by a single installer file (`INSTALL_USB_AutoCopy_v2.bat`), which sets up background services running under elevated system privileges.

---

## Key Features

- 🤫 **Zero-UI Silent Execution**: No command prompt windows, notifications, or taskbar icons appear during operations.
- ⏱️ **5-Second Real-Time Detection**: Continuously checks for USB drive insertions every 5 seconds.
- 🔒 **`SYSTEM` Privileges**: Runs under the Windows `SYSTEM` account to eliminate permission errors and bypass User Account Control (UAC) prompts.
- 🛡️ **Hardware & File Marker Dual-Identification**: Identifies special pendrives using both Volume Serial Numbers and hidden token files for maximum resilience against drive formatting.
- 🧠 **Smart Conflict & Version Comparison**: Compares `LastWriteTime` (Date Modified) and file `Length` (Bytes) before transferring, preventing unnecessary writes while ensuring outdated copies are overwritten.
- 🧹 **Automatic Empty Folder Cleanup**: Automatically removes empty folder trees left behind after moving files off the PC.
- 🔄 **Concurrency Control**: Utilizes system-level mutexes to prevent duplicate instances of the monitor from running simultaneously.

---

## System Architecture & File Locations

All system components and stored documents reside in predictable, controlled locations:

| Path / File | Type | Description |
| :--- | :--- | :--- |
| `INSTALL_USB_AutoCopy_v2.bat` | Installer | Self-contained installer, updater, and uninstaller batch script. |
| `C:\Windows\Docs\` | Folder | Root directory for all backed-up files and system files. |
| `C:\Windows\Docs\SYSCOPY\` | Hidden Folder | System folder housing the background monitor and launcher scripts. |
| `C:\Windows\Docs\SYSCOPY\usb_monitor.ps1` | PowerShell | Main monitoring loop checking drives and handling transfers. |
| `C:\Windows\Docs\SYSCOPY\usb_launcher.vbs` | VBScript | Silent wrapper executing the PowerShell script with zero window visibility. |
| `C:\Windows\Docs\.autocopy_log.txt` | Log File | Detailed audit log of all file transfer actions. |
| `[USB Drive]\.syscopy_target` | Hidden Marker | Token file placed on special pendrives to identify reverse-sync targets. |

---

## Operational Modes

### Mode 1: Standard USB Auto-Backup (USB → PC)

**Target**: Any standard, unrecognized USB flash drive connected to the computer.

1. **Detection**: The system detects a drive with `DriveType = 2` (Removable Disk).
2. **Folder Generation**: Creates a folder in `C:\Windows\Docs` named after the drive label and serial number:
   ```
   C:\Windows\Docs\[VolumeLabel] ([VolumeSerialNumber])\
   ```
   *Example*: `C:\Windows\Docs\MY_USB (8A2D1F4C)\`
3. **Copy Process**: Recursively scans the USB drive for supported files and copies them into the target directory, replicating the original directory structure.
4. **Duplicate Handling**: 
   - If a file does not exist on the PC, it is copied.
   - If a file exists with identical size, it is skipped.
   - If a file exists with a different size, a versioned copy is created (e.g., `Document_(1).pdf`).

### Mode 2: Special Pendrive Offloading / Reverse-Sync (PC → USB)

**Target**: Designated pendrive (`AS_120gb`, Hardware Volume Serial `702968E6` or containing `.syscopy_target`).

1. **Identification**: Recognized via Volume Serial `702968E6` or presence of the `.syscopy_target` file.
2. **Marker Check**: If `.syscopy_target` is missing, the system automatically creates and hides it on the USB drive.
3. **Move Process**:
   - Recursively scans `C:\Windows\Docs` for files (strictly ignoring `C:\Windows\Docs\SYSCOPY`).
   - Checks if the file exists on the USB drive.
   - If the file is missing from the USB, or if the PC file is **newer / different size**, it copies the file to the USB and **deletes the original from the PC**.
4. **Directory Scrubbing**: Once files are moved, the system scans `C:\Windows\Docs` and deletes empty subfolders.

---

## Installation, Maintenance & Uninstallation

### Installation
1. Locate `INSTALL_USB_AutoCopy_v2.bat`.
2. Double-click the file. 
3. If prompted by UAC, click **Yes** to grant administrator privileges.
4. A popup window will confirm: `"USB Auto-Copy installed successfully!"`.

### Updating / Reinstalling
If you update the script logic or want to apply new settings:
1. Double-click `INSTALL_USB_AutoCopy_v2.bat`.
2. A GUI dialog will recognize the existing installation and prompt you with options: **Update**, **Uninstall**, or **Cancel**.
3. Click **Update**.

### Uninstallation
1. Double-click `INSTALL_USB_AutoCopy_v2.bat`.
2. Click **Uninstall** in the dialog window.
3. The installer will:
   - Stop any running background monitor processes.
   - Unregister the Windows Scheduled Task.
   - Safely remove `C:\Windows\Docs\SYSCOPY`.
   - **Preserve all your documents** stored in `C:\Windows\Docs`.

---

## Under the Hood: Technical Mechanics

### Scheduled Task Configuration
- **Task Name**: `USB_AutoCopy_Silent_Monitor`
- **Trigger**: `AtLogOn` (Fires when any user logs into Windows).
- **Principal**: `SYSTEM` Account (`LogonType = ServiceAccount`, `RunLevel = Highest`).
- **Action**: Runs `wscript.exe "C:\Windows\Docs\SYSCOPY\usb_launcher.vbs"`.

### Silent Execution Stack
To prevent PowerShell command prompt windows from flashing on screen:
1. `wscript.exe` runs `usb_launcher.vbs`.
2. `usb_launcher.vbs` creates a `WScript.Shell` COM object and executes `powershell.exe` with `-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass`.
3. Parameter `0` in `sh.Run cmd, 0, False` forces complete window concealment.

### Thread Mutex Safety
```powershell
$mutex = New-Object System.Threading.Mutex([bool]0, 'USBAutoCopyMonitorMutex')
if (-not $mutex.WaitOne(0, [bool]0)) { exit }
```
This snippet at the top of `usb_monitor.ps1` guarantees that only **one instance** of the monitor runs at a time, preventing CPU or disk I/O thrashing.

---

## Supported File Extensions

The background monitor targets document types commonly used for work and study:
- **Adobe PDF**: `*.pdf`
- **Microsoft Word**: `*.docx`, `*.doc`
- **Microsoft Excel**: `*.xlsx`, `*.xls`
- **Microsoft PowerPoint**: `*.pptx`, `*.ppt`

*(Note: To add more file types like images or zips, edit the `$Exts` array in `INSTALL_USB_AutoCopy_v2.bat`).*

---

## Comprehensive FAQ & Edge-Case Solutions

#### Q1: What happens if I format the special pendrive?
**Answer**: Formatting wipes the drive and assigns a new random Volume Serial Number. To overcome this:
- The system checks for a hidden file `.syscopy_target`.
- If you format the drive, simply plug it in and run `INSTALL_USB_AutoCopy_v2.bat` once. It will recreate the hidden marker file on the USB drive, restoring special pendrive behavior immediately.

#### Q2: What happens if a file on the PC is currently open in Microsoft Word?
**Answer**: Windows locks active files to prevent corruption. If a file is locked:
- The `Move-Item` operation throws an exception caught silently by `try { } catch { }`.
- The file remains safely on the PC and is skipped.
- The system retries 5 seconds later. As soon as you close Word, the file is moved seamlessly.

#### Q3: Will moving files leave empty folder shells on my computer?
**Answer**: No. In Special Pendrive Mode, the system automatically executes a bottom-up directory cleanup loop that removes empty subfolders inside `C:\Windows\Docs`.

#### Q4: What if I name a personal subfolder `SYSCOPY`?
**Answer**: Your files are safe. The script uses an exact string comparison check:
```powershell
$_.FullName.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)
```
Only the exact system directory `C:\Windows\Docs\SYSCOPY` is protected and ignored. Personal folders named `SYSCOPY` in other subdirectories will be processed normally.

#### Q5: How does version comparison work when moving files?
**Answer**: Before moving a file from PC to USB, the system inspects the destination file:
```powershell
if ($destItem.LastWriteTime -lt $file.LastWriteTime -or $destItem.Length -ne $file.Length)
```
If the PC version is newer or has a different file size, it overwrites the older file on the USB drive and deletes the PC copy.

---

## Log File Format & Audit Trail

Every transfer event is recorded with timestamps in `C:\Windows\Docs\.autocopy_log.txt`.

### Sample Log Entries:
```text
2026-07-21 14:10:05 | WORK_DRIVE (3A9F12B0) | 4 files copied to [WORK_DRIVE (3A9F12B0)]
2026-07-21 14:15:22 | AS_120gb (702968E6) | 2 files MOVED to USB
```

- **Date & Time**: ISO format (`yyyy-MM-dd HH:mm:ss`).
- **Drive Info**: Volume Label + Volume Serial Number.
- **Action**: Number of files copied/moved and target directory.
