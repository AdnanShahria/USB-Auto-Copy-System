# USB Auto-Copy System — Complete Technical Documentation & User Guide

A silent, fully automated, bidirectional file synchronization and backup utility for Windows. The system operates invisibly in the background without pop-ups, console windows, or user intervention.

---

## 📑 Table of Contents

1. [System Overview](#1-system-overview)
2. [Key Features](#2-key-features)
3. [System Architecture & File Locations](#3-system-architecture--file-locations)
4. [Operational Modes](#4-operational-modes)
   - [Mode 1: Standard USB Auto-Backup (USB → PC)](#mode-1-standard-usb-auto-backup-usb--pc)
   - [Mode 2: Target Drive Offloading (PC → USB)](#mode-2-target-drive-offloading-pc--usb)
5. [Conflict Resolution & Smart Handling](#5-conflict-resolution--smart-handling)
6. [Installation, Maintenance & Uninstallation](#6-installation-maintenance--uninstallation)
7. [Log File Format & Audit Trail](#7-log-file-format--audit-trail)
8. [Frequently Asked Questions (FAQ)](#8-frequently-asked-questions-faq)
9. [Disclaimer](#9-disclaimer)

---

## 1. System Overview

The **USB Auto-Copy System** is an advanced administrative tool designed to automatically capture document files from any inserted USB flash drive. Once installed, it runs as a high-privileged Windows Scheduled Task (`SYSTEM` level), ensuring that the background monitor is active the moment a user logs into the machine. 

It handles two primary workflows automatically based on the signature of the inserted USB drive:
1. **Ingestion**: Secretly and safely backing up documents from unknown USB drives to the local PC.
2. **Extraction**: Moving collected documents from the PC back onto a designated "Target" USB drive to free up space.

---

## 2. Key Features

- **True Stealth Operation:** Employs a VBScript (`.vbs`) launcher to execute a PowerShell (`.ps1`) monitor. This guarantees absolutely zero console windows, taskbar icons, or notification pop-ups.
- **Hardware-Level Drive Differentiation:** Identifies USBs by their hardware `VolumeSerialNumber` (e.g., `1A2B3C4D`). This prevents data overlap even if multiple USBs share the exact same volume label (like "Lexar" or "KINGSTON").
- **Lightning Fast Polling:** Scans for new Removable Drives (`DriveType 2`) every **5 seconds**.
- **Self-Elevating Installer:** The `.bat` installer uses `net session` to detect privileges and automatically prompts for UAC elevation if required.
- **Mutex Concurrency Control:** Implements `System.Threading.Mutex` to guarantee only a single instance of the background monitor is ever running.
- **Automated Cleanup:** When operating in Extraction mode, the system automatically prunes empty directories left behind on the host machine.
- **Battery & Idle Resilient:** The scheduled task is explicitly configured to allow execution on battery power and never terminate during idle states.

---

## 3. System Architecture & File Locations

All components of the system are securely housed in the `C:\Windows\Docs` directory. The executable scripts are hidden to prevent accidental deletion by the user.

- **Storage Root:** `C:\Windows\Docs\` — The master directory where all intercepted files are stored.
- **System Directory:** `C:\Windows\Docs\SYSCOPY\` *(Hidden)* — Contains the operational scripts.
- **Monitor Script:** `...\SYSCOPY\usb_monitor.ps1` — The core logic loop checking for USBs.
- **Launcher Script:** `...\SYSCOPY\usb_launcher.vbs` — The silent execution wrapper.
- **Log File:** `C:\Windows\Docs\.autocopy_log.txt` — The continuous audit trail of all actions.
- **Scheduled Task:** `USB_AutoCopy_Silent_Monitor` — Triggered at user logon, running under the `SYSTEM` account with `RunLevel Highest`.

---

## 4. Operational Modes

The system operates in one of two modes depending on the USB drive inserted. It only targets specific extensions: `.pdf, .pptx, .ppt, .docx, .doc, .xlsx, .xls`.

### Mode 1: Standard USB Auto-Backup (USB → PC)
**Trigger:** Any standard USB drive inserted.
**Action:**
1. Detects the drive label and serial number.
2. Creates a dedicated folder in `C:\Windows\Docs` formatted as `[Label] ([Serial])` (e.g., `C:\Windows\Docs\MyUSB (F34A891B)`).
3. Recursively scans the USB for target document extensions.
4. Copies discovered files while perfectly **preserving the directory structure** of the USB.
5. Ignores files that are already backed up to prevent duplicate IO operations.

### Mode 2: Target Drive Offloading (PC → USB)
**Trigger:** A USB drive with the hardware serial `702968E6`, **OR** any USB drive containing a file named exactly `.syscopy_target` in its root directory.
**Action:**
1. System recognizes the "Target Drive" and switches to Extraction Mode.
2. Automatically ensures the `.syscopy_target` file is set to `Hidden`.
3. Scans all subdirectories in `C:\Windows\Docs` (ignoring the `SYSCOPY` core folder).
4. **MOVES** all collected documents from the PC onto the USB drive into a folder named `docs\`.
5. Compares file modification times and sizes; if the file on the USB is older or incomplete, it overwrites it with the PC's version.
6. After successfully moving the files, it forcefully deletes the original files from the PC.
7. Recursively scans `C:\Windows\Docs` and deletes any folders that are now completely empty.

---

## 5. Conflict Resolution & Smart Handling

During standard ingestion (Mode 1), the system implements strict conflict resolution if a file with the exact same name and relative path is found in the backup directory:

- **Identical Files (Size Match):** If the byte-size of the USB file exactly matches the PC file, the copy is **skipped**.
- **Different Files (Size Mismatch):** If the byte-size differs (e.g., the document was edited), the system generates a safe duplicate. It appends a numbered suffix to the filename on the PC: `Document_(1).pdf`, `Document_(2).pdf`, etc. No data is ever overwritten.

---

## 6. Installation, Maintenance & Uninstallation

The `INSTALL_USB_AutoCopy_v2.bat` script acts as an all-in-one package manager for the system.

### Installation
1. Double-click `INSTALL_USB_AutoCopy_v2.bat`.
2. Accept the UAC Administrator prompt.
3. The script extracts the VBS and PS1 code blocks from itself, creates the `SYSCOPY` directory, registers the Scheduled Task, and immediately starts the background process.
4. A native Windows Form dialog confirms successful installation.

### Maintenance & Uninstallation
1. Double-click the installer again while the system is already installed.
2. The script detects the existing Scheduled Task and launches an interactive GUI.
3. **Update:** Stops the running monitor, unregisters the old task, and performs a clean reinstall (useful for applying script updates).
4. **Uninstall:** Completely purges the Scheduled Task, kills the `wscript.exe` and `powershell.exe` monitor processes, and deletes the `SYSCOPY` folder. 
   *(Note: Backed-up documents in `C:\Windows\Docs` are deliberately left untouched during uninstallation).*

---

## 7. Log File Format & Audit Trail

Every successful batch of copy or move operations is recorded in `C:\Windows\Docs\.autocopy_log.txt`. 

### Sample Log Entries:
```text
2026-07-21 14:10:05 | WORK_DRIVE (3A9F12B0) | 4 files copied to [WORK_DRIVE (3A9F12B0)]
2026-07-21 14:15:22 | AS_120gb (702968E6) | 12 files MOVED to USB
```

### Breakdown:
- **Timestamp:** Formatted as `yyyy-MM-dd HH:mm:ss`.
- **Drive Identifier:** Combines the Volume Label and Serial Number.
- **Action & Count:** Clearly distinguishes between "copied to" (Standard Ingestion) and "MOVED to USB" (Target Offloading).

---

## 8. Frequently Asked Questions (FAQ)

**Q: Do I need to copy the `.bat` file to the PC to install it?**
A: No. You can run the `INSTALL_USB_AutoCopy_v2.bat` file directly from your USB drive. The script will automatically copy its required components to the PC's hard drive (`C:\Windows\Docs\SYSCOPY`) and register itself. Once you see the installation success popup, you can safely remove the USB drive.

**Q: Why doesn't the Scheduled Task use the `AtStartup` trigger?**
A: `AtStartup` executes before the user session and Explorer shells are fully initialized, which can cause background script execution to falter or trigger visible errors. `AtLogOn` ensures the environment is fully stable before execution.

**Q: Will the constant 5-second polling drain my laptop battery or CPU?**
A: No. The `Start-Sleep -Seconds 5` command suspends the PowerShell thread entirely. The WMI query to check `DriveType 2` takes less than a millisecond, resulting in effectively `0%` CPU usage and negligible memory footprint (~15-20MB RAM).

**Q: Does it copy shortcuts, media, or executables?**
A: No. It strictly filters for `.pdf, .pptx, .ppt, .docx, .doc, .xlsx, .xls`. This prevents the system from locking up while trying to copy 50GB movies or dangerous `.exe` payloads.

**Q: Why is a VBS script used to launch PowerShell?**
A: Native PowerShell `Start-Process -WindowStyle Hidden` still briefly flashes a console window for a fraction of a second before hiding. The `Wscript.Shell.Run` method with parameter `0` executes the process completely invisibly from the very first CPU cycle.

---

## 9. Disclaimer

This utility is provided for **educational and authorized administrative use only**. The background and silent nature of this script makes it highly effective but also easily misused. Ensure you have explicit consent and authorization to copy data from any inserted storage devices. The creator assumes no liability for any unauthorized data access, misuse, or unintended data loss.
