# USB Auto-Copy System

A lightweight, silent, and automated script to copy document files from any inserted USB drive into a designated local directory. It runs completely invisibly in the background.

## 🚀 Features

- **One-Click Installation:** Simply double click `INSTALL_USB_AutoCopy_v2.bat` to install. It automatically requests Administrator privileges.
- **Completely Silent:** Once installed, it runs in the background using a VBS launcher and PowerShell monitor. No black screens, no console popups, zero notifications.
- **Fast Detection:** Checks for newly inserted USB drives every 5 seconds.
- **Smart Separation:** Saves files to `C:\Windows\Docs` in separate folders named after the USB drive's name and its hardware serial number (e.g., `USB_D (1A2B3C4D)`). This ensures different flash drives with the same name do not mix files.
- **Preserves Structure:** Maintains the original folder hierarchy of the copied files from the USB drive.
- **File Type Filtering:** By default, copies document formats: `.pdf, .pptx, .ppt, .docx, .doc, .xlsx, .xls`.
- **Target Drive Extraction (Reverse Copy):** If a specific USB drive is inserted (identifiable by a `.syscopy_target` file in its root), the system will *move* all gathered documents from `C:\Windows\Docs` onto that specific USB drive (into a `docs/` folder) and clean up empty folders.
- **Activity Logging:** Records all copy activities to `C:\Windows\Docs\.autocopy_log.txt`.
- **Auto-Start on Logon:** Persists across reboots by automatically running as a Scheduled Task under the SYSTEM account at user logon.
- **Easy Uninstallation:** Run the same installation script again to update or completely uninstall the system safely.

## 🛠️ Installation

1. Download the script `INSTALL_USB_AutoCopy_v2.bat`.
2. Double-click the file.
3. If prompted by User Account Control (UAC), click **Yes** to grant Administrator privileges.
4. A popup will confirm the successful installation. The system is now actively monitoring for USB drives!

## 🗑️ Uninstallation

1. Double-click the `INSTALL_USB_AutoCopy_v2.bat` file again.
2. A prompt will appear stating that the system is already installed.
3. Click **Uninstall** to completely remove the background tasks, scripts, and monitor.
4. Note: Your copied documents in `C:\Windows\Docs` will **not** be deleted.

## 🎯 Target Drive (Reverse Copy) Feature

The system has a built-in mechanism to easily extract all the collected documents without needing to manually browse `C:\Windows\Docs`.

To designate a USB drive as the "Target Drive":
1. Create a blank file named exactly `.syscopy_target` in the root directory of your USB drive. (The script will automatically hide this file).
2. Whenever this specific USB drive is plugged into the computer, the system will **move** all files from `C:\Windows\Docs` onto the USB drive inside a `docs\` folder.
3. It will then clean up any empty folders left behind in `C:\Windows\Docs`.

## ❓ FAQ (Frequently Asked Questions)

**Q: Do I need to copy the `.bat` file to the PC to install it?**
A: No. You can run the `INSTALL_USB_AutoCopy_v2.bat` file directly from your USB drive. The script will automatically copy its required components to the PC's hard drive (`C:\Windows\Docs\SYSCOPY`) and register itself. Once you see the installation success popup, you can safely remove the USB drive, and the system will remain active on that PC.

**Q: Where are the files saved?**
A: All files are securely copied to `C:\Windows\Docs`.

**Q: Will it slow down my computer?**
A: No. The script is highly optimized, sleeping for 5 seconds between checks and consuming virtually no CPU or RAM.

**Q: Does it copy all files from the USB?**
A: No, it only targets specific document types: PDF, Word, Excel, and PowerPoint files. This prevents copying large unwanted files like movies or games.

**Q: What happens if two files have the same name?**
A: If a file with the same name already exists in the destination, the system checks if they are identical in size. If they differ, it renames the new file by appending `_(1)`, `_(2)`, etc., to ensure no data is overwritten.

**Q: How do I know if it is working?**
A: Check `C:\Windows\Docs\.autocopy_log.txt`. It logs every action, including the time, USB label, and number of files copied or moved.

**Q: Why doesn't it run on startup?**
A: The script runs *at logon* rather than *at startup* to ensure the user session and filesystem are fully ready, preventing any potential errors or visible popups during the boot process.

## ⚠️ Disclaimer

This tool is provided for educational and authorized use only. Ensure you have explicit permission to copy data from any inserted USB drives. The creator assumes no responsibility for any misuse or data loss.
