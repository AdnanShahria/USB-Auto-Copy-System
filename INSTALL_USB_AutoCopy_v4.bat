@echo off
setlocal
:: ============================================================
:: USB Monitor v4.2 - Silent Installer
:: ============================================================
:: Features:
::   * Safe batch/PS bootstrap (immune to special chars & line shifts)
::   * Global\ mutex + AbandonedMutexException recovery
::   * Interactive elevated Scheduled Task (zero console flash + 1s GUI toasts)
::   * Target USB 1-second toast notifications ("Starting..." -> "OK")
::   * Multi-method Target USB detection: .syscopy_target, Hardware/Volume Serial, or LABEL:
::   * Ignore support (.syscopy_ignore or ignore.txt)
::   * Atomic .tmp/.bak Safe-CopyFile for BOTH Source and Target USBs
::   * Exact extension HashSet + single-pass scan + \\?\ long-path support
::   * Cached case-insensitive index + periodic atomic log/index maintenance
::   * Stored in C:\ProgramData\USB with hardened SYSCOPY ACLs
:: ============================================================
:: Double-click ONCE to install.
:: Double-click again to update, add a Target USB, or uninstall.
:: ============================================================
set "BAT_SELF=%~f0"
net session >nul 2>&1
if errorlevel 1 goto :elevate

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$lines = [System.IO.File]::ReadAllLines($env:BAT_SELF, [System.Text.Encoding]::UTF8); $idx = [Array]::IndexOf($lines, '# === PS_PAYLOAD_START ==='); if ($idx -lt 0) { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Installer payload marker not found.', 'USB', 'OK', 'Error') | Out-Null; exit 2 }; $tmp = Join-Path $env:TEMP ('uac_' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { [System.IO.File]::WriteAllLines($tmp, [string[]]$lines[($idx + 1)..($lines.Count - 1)], [System.Text.Encoding]::UTF8); & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $tmp; exit $LASTEXITCODE } catch { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Installer error: ' + $_.Exception.Message, 'USB', 'OK', 'Error') | Out-Null; exit 1 } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }"
exit /b %errorlevel%

:elevate
powershell.exe -NoProfile -WindowStyle Hidden -Command "try { Start-Process -FilePath $env:BAT_SELF -Verb RunAs -WindowStyle Hidden } catch { $code = if ($_.Exception.InnerException) { $_.Exception.InnerException.NativeErrorCode } else { $_.Exception.NativeErrorCode }; if ($code -ne 1223) { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Administrator elevation failed: ' + $_.Exception.Message, 'USB', 'OK', 'Warning') | Out-Null } }"
exit /b
# === PS_PAYLOAD_START ===
# ============================================================
# USB Monitor v4.2 - PowerShell Installer Block
# ============================================================

# ---- PATHS ----
$DestRoot        = 'C:\ProgramData\USB'
$DocsDir         = Join-Path $DestRoot 'docs'
$InstallDir      = Join-Path $DestRoot 'SYSCOPY'
$MonitorPS1      = Join-Path $InstallDir 'usb_monitor.ps1'
$LauncherVBS     = Join-Path $InstallDir 'usb_launcher.vbs'
$IndexFile       = Join-Path $InstallDir 'systemcopydocs.index'
$LogFile         = Join-Path $InstallDir 'usb_log.txt'
$TargetsFile     = Join-Path $InstallDir 'targets.txt'
$IgnoreFile      = Join-Path $InstallDir 'ignore.txt'
$LegacySysDirs   = @('C:\ProgramData\USBAutoCopy\SYSCOPY', 'C:\Windows\Downloaded Win Docs\SYSCOPY')
$TaskName        = 'USB_Monitor'
$LegacyTaskNames = @('USB_AutoCopy_Silent_Monitor')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$nl = [Environment]::NewLine

# ---- HELPER: Stop scheduled tasks & wait for monitor processes to exit ----
function Stop-MonitorProcesses {
    foreach ($tn in (@($TaskName) + $LegacyTaskNames)) {
        try { Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue } catch {}
    }

    $targetPids = New-Object System.Collections.Generic.List[int]
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            $cmd = $p.CommandLine
            if ([string]::IsNullOrEmpty($cmd)) { continue }
            if (($p.Name -ieq 'powershell.exe' -and $cmd -match 'SYSCOPY\\usb_monitor\.ps1') -or
                ($p.Name -ieq 'wscript.exe' -and $cmd -match 'SYSCOPY\\usb_launcher\.vbs')) {
                if ($p.ProcessId -ne $PID) {
                    $targetPids.Add([int]$p.ProcessId)
                }
            }
        }
    } catch {}

    foreach ($procId in $targetPids) {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
    }

    if ($targetPids.Count -gt 0) {
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            $stillAlive = $false
            foreach ($procId in $targetPids) {
                if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
                    $stillAlive = $true
                    break
                }
            }
            if (-not $stillAlive) { break }
            Start-Sleep -Milliseconds 200
        }
    }
}

# ---- HELPER: Harden SYSCOPY directory ACL (SYSTEM + Administrators only) ----
function Protect-InstallDirectory([string]$dirPath) {
    try {
        $acl = Get-Acl -LiteralPath $dirPath -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            [void]$acl.RemoveAccessRule($rule)
        }

        $sysSid   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $inherit  = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $prop     = [System.Security.AccessControl.PropagationFlags]::None
        $rights   = [System.Security.AccessControl.FileSystemRights]::FullControl
        $allow    = [System.Security.AccessControl.AccessControlType]::Allow

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sysSid, $rights, $inherit, $prop, $allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminSid, $rights, $inherit, $prop, $allow)))

        Set-Acl -LiteralPath $dirPath -AclObject $acl -ErrorAction Stop
    } catch {}
}

# ---- HELPER: Register currently connected USB drive(s) as Target in targets.txt ----
function Add-TargetUsbDialog {
    $sysId = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\').ToUpperInvariant() } else { 'C:' }
    $ready = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
        try { $_.IsReady -and $_.TotalSize -gt 0 -and $_.Name.TrimEnd('\').ToUpperInvariant() -ne $sysId } catch { $false }
    })

    $logicalMap = @{}
    try {
        foreach ($ld in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrEmpty($ld.DeviceID)) { $logicalMap[$ld.DeviceID.ToUpperInvariant()] = $ld }
        }
    } catch {}

    $hwMap = @{}
    try {
        foreach ($md in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' })) {
            $hw = if ($md.SerialNumber) { $md.SerialNumber.Trim() } else { '' }
            foreach ($mp in @(Get-Partition -DiskNumber $md.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
                $did = $mp.DriveLetter.ToString().ToUpperInvariant() + ':'
                if ($hw -ne '' -and $hw -notmatch '^0+$') { $hwMap[$did] = $hw }
            }
        }
    } catch {}

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($d in $ready) {
        $id = $d.Name.TrimEnd('\').ToUpperInvariant()
        if ($d.DriveType -eq [System.IO.DriveType]::Removable -or $hwMap.ContainsKey($id)) {
            $ld  = $logicalMap[$id]
            $vol = if ($ld -and $ld.VolumeSerialNumber) { $ld.VolumeSerialNumber.Trim().ToUpperInvariant() } else { '' }
            $hw  = if ($hwMap.ContainsKey($id)) { $hwMap[$id] } else { '' }
            $lbl = ''
            try { $lbl = $d.VolumeLabel } catch {}
            $candidates.Add([PSCustomObject]@{
                DeviceID = $id
                Label    = if ([string]::IsNullOrWhiteSpace($lbl)) { 'NoLabel' } else { $lbl.Trim() }
                VolSer   = $vol
                HwSer    = $hw
                Display  = ($id + '  ' + $(if ([string]::IsNullOrWhiteSpace($lbl)) { 'NoLabel' } else { $lbl.Trim() }) + '  [Vol:' + $vol + $(if ($hw -ne '') { ' | HW:' + $hw } else { '' }) + ']')
            })
        }
    }

    if ($candidates.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No connected USB drive found. Plug in your Target USB and try again.', 'USB', 'OK', 'Information') | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    try {
        $dlg.Text = 'USB - Add Target Drive'
        $dlg.Size = New-Object System.Drawing.Size(440, 220)
        $dlg.StartPosition = 'CenterScreen'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.TopMost = $true

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'Select your Target USB drive (no .syscopy_target file needed):'
        $lbl.Location = New-Object System.Drawing.Point(12, 12)
        $lbl.AutoSize = $true
        $dlg.Controls.Add($lbl)

        $lb = New-Object System.Windows.Forms.ListBox
        $lb.Location = New-Object System.Drawing.Point(12, 36)
        $lb.Size = New-Object System.Drawing.Size(400, 95)
        foreach ($c in $candidates) { [void]$lb.Items.Add($c.Display) }
        $lb.SelectedIndex = 0
        $dlg.Controls.Add($lb)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = 'Add as Target'
        $btnOk.Location = New-Object System.Drawing.Point(210, 142)
        $btnOk.Size = New-Object System.Drawing.Size(105, 28)
        $btnOk.DialogResult = 'OK'
        $dlg.Controls.Add($btnOk)

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = 'Close'
        $btnClose.Location = New-Object System.Drawing.Point(325, 142)
        $btnClose.Size = New-Object System.Drawing.Size(87, 28)
        $btnClose.DialogResult = 'Cancel'
        $dlg.Controls.Add($btnClose)

        $dlg.AcceptButton = $btnOk
        $dlg.CancelButton = $btnClose

        if ($dlg.ShowDialog() -eq 'OK' -and $lb.SelectedIndex -ge 0) {
            $sel = $candidates[$lb.SelectedIndex]
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $existing = if (Test-Path -LiteralPath $TargetsFile) { @([System.IO.File]::ReadAllLines($TargetsFile, [System.Text.Encoding]::UTF8)) } else { @() }
            $added = New-Object System.Collections.Generic.List[string]
            foreach ($entry in @($sel.HwSer, $sel.VolSer)) {
                if (-not [string]::IsNullOrWhiteSpace($entry) -and ($existing -notcontains $entry)) {
                    [System.IO.File]::AppendAllText($TargetsFile, $entry + [Environment]::NewLine, $utf8NoBom)
                    $added.Add($entry)
                }
            }
            if ($added.Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show('Added Target USB identifier(s):' + $nl + ($added -join $nl), 'USB', 'OK', 'Information') | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show('This USB is already registered in targets.txt.', 'USB', 'OK', 'Information') | Out-Null
            }
        }
    } finally {
        $dlg.Dispose()
    }
}

# ---- Check existing installation BEFORE mutating filesystem ----
$existingTask = $null
foreach ($tn in (@($TaskName) + $LegacyTaskNames)) {
    try {
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction Stop
        if ($t) { $existingTask = $t; break }
    } catch {}
}

if ($existingTask) {
    $form = New-Object System.Windows.Forms.Form
    $result = 'Cancel'
    try {
        $form.Text = 'USB Setup'
        $form.Size = New-Object System.Drawing.Size(420, 145)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $label = New-Object System.Windows.Forms.Label
        $label.Location = New-Object System.Drawing.Point(14, 15)
        $label.AutoSize = $true
        $label.Text = 'USB is already installed.'
        $form.Controls.Add($label)

        $btnUpdate = New-Object System.Windows.Forms.Button
        $btnUpdate.Location = New-Object System.Drawing.Point(14, 55)
        $btnUpdate.Size = New-Object System.Drawing.Size(80, 30)
        $btnUpdate.Text = 'Update'
        $btnUpdate.DialogResult = 'Yes'
        $form.Controls.Add($btnUpdate)

        $btnAddTarget = New-Object System.Windows.Forms.Button
        $btnAddTarget.Location = New-Object System.Drawing.Point(102, 55)
        $btnAddTarget.Size = New-Object System.Drawing.Size(110, 30)
        $btnAddTarget.Text = 'Add Target USB'
        $btnAddTarget.DialogResult = 'Retry'
        $form.Controls.Add($btnAddTarget)

        $btnUninstall = New-Object System.Windows.Forms.Button
        $btnUninstall.Location = New-Object System.Drawing.Point(220, 55)
        $btnUninstall.Size = New-Object System.Drawing.Size(86, 30)
        $btnUninstall.Text = 'Uninstall'
        $btnUninstall.DialogResult = 'No'
        $form.Controls.Add($btnUninstall)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Location = New-Object System.Drawing.Point(314, 55)
        $btnCancel.Size = New-Object System.Drawing.Size(78, 30)
        $btnCancel.Text = 'Cancel'
        $btnCancel.DialogResult = 'Cancel'
        $form.Controls.Add($btnCancel)

        $form.AcceptButton = $btnUpdate
        $form.CancelButton = $btnCancel
        $form.TopMost = $true
        $result = $form.ShowDialog()
    } finally {
        $form.Dispose()
    }

    if ($result -eq 'Cancel') { exit 0 }

    if ($result -eq 'Retry') {
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            [System.Windows.Forms.MessageBox]::Show('Please click Update first to complete setup.', 'USB', 'OK', 'Information') | Out-Null
            exit 0
        }
        Add-TargetUsbDialog
        exit 0
    }

    if ($result -eq 'No') {
        Stop-MonitorProcesses
        foreach ($tn in (@($TaskName) + $LegacyTaskNames)) {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
        }

        $removeErrors = New-Object System.Collections.Generic.List[string]
        foreach ($dirToRemove in (@($InstallDir) + $LegacySysDirs)) {
            if (Test-Path -LiteralPath $dirToRemove) {
                try {
                    Remove-Item -LiteralPath $dirToRemove -Recurse -Force -ErrorAction Stop
                } catch {
                    $removeErrors.Add($dirToRemove + ': ' + $_.Exception.Message)
                }
            }
        }

        if ($removeErrors.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Uninstalled successfully.' + $nl +
                'Your documents in ' + $DocsDir + ' are kept safe.' + $nl +
                'The SYSCOPY folder and index have been removed.',
                'USB', 'OK', 'Information'
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                'Task removed, but some SYSCOPY files could not be deleted:' + $nl + ($removeErrors -join $nl),
                'USB - Warning', 'OK', 'Warning'
            ) | Out-Null
        }
        exit 0
    }

    # Update path: stop old task/processes before overwriting files
    Stop-MonitorProcesses
    foreach ($tn in (@($TaskName) + $LegacyTaskNames)) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---- Create directories & harden SYSCOPY ----
foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
try {
    $instItem = Get-Item -LiteralPath $InstallDir -Force
    $instItem.Attributes = $instItem.Attributes -bor [System.IO.FileAttributes]::Hidden
} catch {}
Protect-InstallDirectory $InstallDir

# Migrate legacy docs & index if updating from C:\ProgramData\USBAutoCopy
$legacyDocsDir = 'C:\ProgramData\USBAutoCopy\docs'
if (Test-Path -LiteralPath $legacyDocsDir) {
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $legacyDocsDir -Force -ErrorAction SilentlyContinue)) {
            $targetItemPath = Join-Path $DocsDir $item.Name
            if (-not (Test-Path -LiteralPath $targetItemPath)) {
                Move-Item -LiteralPath $item.FullName -Destination $targetItemPath -Force -ErrorAction SilentlyContinue
            }
        }
        if (@(Get-ChildItem -LiteralPath $legacyDocsDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $legacyDocsDir -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

if (-not (Test-Path -LiteralPath $IndexFile)) {
    foreach ($legDir in $LegacySysDirs) {
        $legIdx = Join-Path $legDir 'systemcopydocs.index'
        if (Test-Path -LiteralPath $legIdx) {
            try { Copy-Item -LiteralPath $legIdx -Destination $IndexFile -Force -ErrorAction Stop; break } catch {}
        }
    }
    if (-not (Test-Path -LiteralPath $IndexFile)) {
        Set-Content -LiteralPath $IndexFile -Value '' -Encoding UTF8
    }
}

# Initialize targets.txt and ignore.txt templates if not present
$utf8NoBomInit = New-Object System.Text.UTF8Encoding($false)
if (-not (Test-Path -LiteralPath $TargetsFile)) {
    $tHeader = @(
        '# Target USB allowlist (one entry per line, # = comment)'
        '# Supported entries:'
        '#   - Hardware disk serial (e.g. 0401A2B3C4D5E6F7) — survives reformatting'
        '#   - Volume serial number (e.g. 702968E6)'
        '#   - Volume label prefix  (e.g. LABEL:MY_USB)'
        '# Any USB with a .syscopy_target file in its root is also treated as Target.'
    )
    [System.IO.File]::WriteAllLines($TargetsFile, $tHeader, $utf8NoBomInit)
}
if (-not (Test-Path -LiteralPath $IgnoreFile)) {
    $iHeader = @(
        '# Ignored USB allowlist (one entry per line, # = comment)'
        '# Matching USBs are skipped completely (neither copied from nor offloaded to).'
        '# Supported: Hardware serial, Volume serial, or LABEL:DriveName'
        '# Any USB with a .syscopy_ignore file in its root is also ignored.'
    )
    [System.IO.File]::WriteAllLines($IgnoreFile, $iHeader, $utf8NoBomInit)
}

# Clean up legacy scripts folders if present (leaves legacy docs untouched)
foreach ($legDir in $LegacySysDirs) {
    if (Test-Path -LiteralPath $legDir) {
        Remove-Item -LiteralPath $legDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# MONITOR SCRIPT (embedded, written to disk on install)
# ============================================================
$monitorCode = @'
# ============================================================
# USB Monitor v4.2
# ============================================================

# ---- SINGLE-INSTANCE GLOBAL MUTEX (with AbandonedMutex recovery) ----
$mutex = $null
$hasMutex = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\USBMonitorMutexV4')
    try {
        $hasMutex = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $hasMutex = $true
    }
} catch {
    exit 1
}

if (-not $hasMutex) {
    if ($mutex) { $mutex.Dispose() }
    exit 0
}

try {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    } catch {}

    # ---- CONSTANTS ----
    $DestRoot        = 'C:\ProgramData\USB'
    $DocsDir         = Join-Path $DestRoot 'docs'
    $InstallDir      = Join-Path $DestRoot 'SYSCOPY'
    $IndexFile       = Join-Path $InstallDir 'systemcopydocs.index'
    $LogFile         = Join-Path $InstallDir 'usb_log.txt'
    $TargetsFile     = Join-Path $InstallDir 'targets.txt'
    $IgnoreFile      = Join-Path $InstallDir 'ignore.txt'
    $MAX_LOG_LINES   = 2000
    $MAX_INDEX_LINES = 10000
    $EpochUtc        = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)
    $SystemDriveId   = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\').ToUpperInvariant() } else { 'C:' }

    $AllowedExts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in @('.pdf', '.pptx', '.ppt', '.docx', '.doc', '.xlsx', '.xls')) {
        [void]$AllowedExts.Add($ext)
    }

    # ---- ENSURE DIRECTORIES ----
    foreach ($dir in @($DestRoot, $DocsDir, $InstallDir)) {
        if (-not [System.IO.Directory]::Exists($dir)) {
            [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        }
    }

    # ============================================================
    # 1-SECOND GUI TOAST NOTIFICATION (Starting... / OK)
    # Borderless, TopMost, auto-closes after durationMs (1000ms)
    # ============================================================
    function Show-BriefToast([string]$message, [int]$durationMs, [int]$r, [int]$g, [int]$b) {
        try {
            $form = New-Object System.Windows.Forms.Form
            $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
            $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
            $form.ShowInTaskbar   = $false
            $form.TopMost         = $true
            $form.MinimumSize     = New-Object System.Drawing.Size(1, 1)
            $form.Size            = New-Object System.Drawing.Size(136, 38)
            $form.BackColor       = [System.Drawing.Color]::FromArgb($r, $g, $b)

            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - 12), ($wa.Top + 12))

            $lblTitle = New-Object System.Windows.Forms.Label
            $lblTitle.Text      = 'USB'
            $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(225, 235, 245)
            $lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
            $lblTitle.Location  = New-Object System.Drawing.Point(9, 4)
            $lblTitle.AutoSize  = $true
            $form.Controls.Add($lblTitle)

            $lblMsg = New-Object System.Windows.Forms.Label
            $lblMsg.Text      = $message
            $lblMsg.ForeColor = [System.Drawing.Color]::White
            $lblMsg.Font      = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
            $lblMsg.Location  = New-Object System.Drawing.Point(9, 17)
            $lblMsg.AutoSize  = $true
            $form.Controls.Add($lblMsg)

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = $durationMs
            $timer.Tag = $form
            $timer.Add_Tick({
                param($sender, $e)
                $sender.Stop()
                if ($sender.Tag) { $sender.Tag.Close() }
            })

            $form.Tag = $timer
            $form.Add_Shown({
                param($sender, $e)
                if ($sender.Tag) { $sender.Tag.Start() }
            })

            try {
                [void]$form.ShowDialog()
            } finally {
                $timer.Dispose()
                $form.Dispose()
            }
        } catch {}
    }

    # ============================================================
    # ALLOWLIST HELPERS (targets.txt / ignore.txt)
    # ============================================================
    function Load-RuleSet([string]$filePath) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        if (-not [System.IO.File]::Exists($filePath)) { return ,$set }
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)) {
                $t = $line.Trim()
                if ($t -eq '' -or $t.StartsWith('#')) { continue }
                [void]$set.Add($t)
            }
        } catch {}
        return ,$set
    }

    function Test-DriveMatchesRuleSet($drv, $ruleSet) {
        if ($ruleSet -eq $null -or $ruleSet.Count -eq 0) { return $false }
        if ($drv.Serial -ne 'NOSERIAL' -and $ruleSet.Contains($drv.Serial)) { return $true }
        if (-not [string]::IsNullOrEmpty($drv.HwSerial) -and $ruleSet.Contains($drv.HwSerial)) { return $true }
        if (-not [string]::IsNullOrEmpty($drv.Label) -and $ruleSet.Contains('LABEL:' + $drv.Label)) { return $true }
        return $false
    }

    # ============================================================
    # PATH HELPERS (Extended-length \\?\ support for >260 chars)
    # ============================================================
    function ConvertTo-SafePath([string]$p) {
        if ([string]::IsNullOrEmpty($p)) { return $p }
        if ($p.Length -lt 240 -or $p.StartsWith('\\?\')) { return $p }
        if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
        return '\\?\' + $p
    }

    function Strip-LongPathPrefix([string]$p) {
        if ([string]::IsNullOrEmpty($p)) { return $p }
        if ($p.StartsWith('\\?\UNC\')) { return '\\' + $p.Substring(8) }
        if ($p.StartsWith('\\?\')) { return $p.Substring(4) }
        return $p
    }

    # ============================================================
    # LOGGING & ATOMIC ROTATION
    # ============================================================
    function Write-Log([string]$msg) {
        $entry = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $msg
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try {
                [System.IO.File]::AppendAllText($LogFile, $entry + [Environment]::NewLine, $Utf8NoBom)
                return
            } catch {
                Start-Sleep -Milliseconds 50
            }
        }
    }

    function Rotate-Log {
        try {
            if (-not [System.IO.File]::Exists($LogFile)) { return }
            $logLines = @([System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8))
            if ($logLines.Count -gt $MAX_LOG_LINES) {
                $trimmed = $logLines[($logLines.Count - $MAX_LOG_LINES)..($logLines.Count - 1)]
                $tmpLog  = $LogFile + '.tmp'
                [System.IO.File]::WriteAllLines($tmpLog, [string[]]$trimmed, $Utf8NoBom)
                [System.IO.File]::Replace($tmpLog, $LogFile, $null, $true)
                Write-Log ('LOG ROTATED: trimmed to last ' + $MAX_LOG_LINES + ' lines')
            }
        } catch {
            try { if ([System.IO.File]::Exists($LogFile + '.tmp')) { [System.IO.File]::Delete($LogFile + '.tmp') } } catch {}
        }
    }

    # ============================================================
    # STARTUP RECOVERY: Clean leftover .tmp / .bak files
    # ============================================================
    function Clean-LeftoverTempFiles([string]$rootDir) {
        if (-not [System.IO.Directory]::Exists($rootDir)) { return }
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($rootDir)
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            $lp  = ConvertTo-SafePath $cur
            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($lp)) {
                    if ($f.EndsWith('.tmp', [System.StringComparison]::OrdinalIgnoreCase) -or
                        $f.EndsWith('.bak', [System.StringComparison]::OrdinalIgnoreCase)) {
                        try {
                            [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal)
                            [System.IO.File]::Delete($f)
                        } catch {}
                    }
                }
            } catch {}
            try {
                foreach ($d in [System.IO.Directory]::EnumerateDirectories($lp)) {
                    try {
                        $di = New-Object System.IO.DirectoryInfo($d)
                        if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                            $stack.Push((Strip-LongPathPrefix $di.FullName))
                        }
                    } catch {}
                }
            } catch {}
        }
    }

    # ============================================================
    # SINGLE-PASS FILE ENUMERATOR (with diagnostics & error logging)
    # ============================================================
    $script:LastScanStats = @{ Dirs = 0; TotalFiles = 0; Matched = 0; ExcludedDocs = 0; ScanErrors = 0 }

    function Get-MatchingFiles([string]$rootDir, [string]$excludeDir) {
        $results = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        $stack   = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($rootDir)

        $stats = @{ Dirs = 0; TotalFiles = 0; Matched = 0; ExcludedDocs = 0; ScanErrors = 0 }

        $normExclude = $null
        if (-not [string]::IsNullOrEmpty($excludeDir)) {
            $normExclude = $excludeDir.TrimEnd('\') + '\'
        }

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            if (-not [string]::IsNullOrEmpty($normExclude)) {
                $normCur = $current.TrimEnd('\') + '\'
                if ($normCur.Equals($normExclude, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $normCur.StartsWith($normExclude, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $stats.ExcludedDocs++
                    continue
                }
            }

            $stats.Dirs++
            $lpCurrent = ConvertTo-SafePath $current
            try {
                foreach ($fPath in [System.IO.Directory]::EnumerateFiles($lpCurrent)) {
                    $stats.TotalFiles++
                    try {
                        $fi = New-Object System.IO.FileInfo($fPath)
                        if ($fi.Name.StartsWith('~$')) { continue }
                        if ($AllowedExts.Contains($fi.Extension)) {
                            $results.Add($fi)
                            $stats.Matched++
                        }
                    } catch {
                        $stats.ScanErrors++
                    }
                }
            } catch {
                $stats.ScanErrors++
                Write-Log ('SCAN FILE ERROR [' + $current + ']: ' + $_.Exception.Message)
            }

            try {
                foreach ($dPath in [System.IO.Directory]::EnumerateDirectories($lpCurrent)) {
                    try {
                        $di = New-Object System.IO.DirectoryInfo($dPath)
                        if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        if ($di.Name -ieq '$RECYCLE.BIN' -or $di.Name -ieq 'System Volume Information') { continue }
                        $stack.Push((Strip-LongPathPrefix $di.FullName))
                    } catch {
                        $stats.ScanErrors++
                    }
                }
            } catch {
                $stats.ScanErrors++
                Write-Log ('SCAN DIR ERROR [' + $current + ']: ' + $_.Exception.Message)
            }
        }
        $script:LastScanStats = $stats
        return ,$results
    }

    # ============================================================
    # BOTTOM-UP EMPTY FOLDER CLEANUP
    # ============================================================
    function Remove-EmptyDirectories([string]$baseDir) {
        if (-not [System.IO.Directory]::Exists($baseDir)) { return }
        $dirs  = New-Object System.Collections.Generic.List[string]
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($baseDir)

        while ($stack.Count -gt 0) {
            $cur = $stack.Pop()
            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories((ConvertTo-SafePath $cur))) {
                    $cleanSub = Strip-LongPathPrefix $sub
                    $dirs.Add($cleanSub)
                    $stack.Push($cleanSub)
                }
            } catch {}
        }

        $sorted = @($dirs | Sort-Object -Property Length -Descending)
        foreach ($d in $sorted) {
            try {
                $lp = ConvertTo-SafePath $d
                $hasEntry = $false
                foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($lp)) {
                    $hasEntry = $true
                    break
                }
                if (-not $hasEntry) {
                    [System.IO.Directory]::Delete($lp, $false)
                }
            } catch {}
        }
    }

    # ============================================================
    # INDEX FUNCTIONS (Case-insensitive, cached, atomic compaction)
    # ============================================================
    $script:IndexSet       = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $script:IndexLoaded    = $false
    $script:IndexLastWrite = [System.DateTime]::MinValue
    $script:IndexLength    = -1L

    function Get-IndexKey([string]$serial, [string]$relPath, [System.IO.FileInfo]$file) {
        $mtimeBucket = [long][Math]::Floor(($file.LastWriteTimeUtc - $EpochUtc).TotalSeconds / 2.0)
        return ($serial + '|' + $relPath + '|' + $file.Length.ToString() + '|' + $mtimeBucket.ToString())
    }

    function Sync-IndexCache([string]$indexPath) {
        if (-not [System.IO.File]::Exists($indexPath)) {
            $script:IndexSet       = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $script:IndexLoaded    = $true
            $script:IndexLastWrite = [System.DateTime]::MinValue
            $script:IndexLength    = -1L
            return
        }

        $fi = New-Object System.IO.FileInfo($indexPath)
        if ($script:IndexLoaded -and
            $fi.LastWriteTimeUtc -eq $script:IndexLastWrite -and
            $fi.Length -eq $script:IndexLength) {
            return
        }

        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $lines = [System.IO.File]::ReadAllLines($indexPath, [System.Text.Encoding]::UTF8)
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '') { continue }
                $parts = $trimmed.Split('|')
                if ($parts.Count -eq 4 -or $parts.Count -eq 3) {
                    [void]$set.Add($trimmed)
                }
            }
        } catch {
            Write-Log ('INDEX LOAD ERROR: ' + $_.Exception.Message)
        }

        $script:IndexSet       = $set
        $script:IndexLoaded    = $true
        $script:IndexLastWrite = $fi.LastWriteTimeUtc
        $script:IndexLength    = $fi.Length
    }

    function Add-ToIndex([string]$indexPath, [string]$key) {
        try {
            [System.IO.File]::AppendAllText($indexPath, $key + [Environment]::NewLine, $Utf8NoBom)
            [void]$script:IndexSet.Add($key)
            $fi = New-Object System.IO.FileInfo($indexPath)
            $script:IndexLoaded    = $true
            $script:IndexLastWrite = $fi.LastWriteTimeUtc
            $script:IndexLength    = $fi.Length
            return $true
        } catch {
            Write-Log ('INDEX WRITE ERROR: ' + $_.Exception.Message)
            return $false
        }
    }

    function Compact-Index([string]$indexPath) {
        $tmpIndex = $indexPath + '.tmp'
        try {
            if (-not [System.IO.File]::Exists($indexPath)) { return }
            $lines = @([System.IO.File]::ReadAllLines($indexPath, [System.Text.Encoding]::UTF8))
            if ($lines.Count -le $MAX_INDEX_LINES) { return }

            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $kept = New-Object System.Collections.Generic.List[string]
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $trimmed = $lines[$i].Trim()
                if ($trimmed -eq '') { continue }
                $parts = $trimmed.Split('|')
                if (($parts.Count -eq 4 -or $parts.Count -eq 3) -and $seen.Add($trimmed)) {
                    $kept.Add($trimmed)
                    if ($kept.Count -ge $MAX_INDEX_LINES) { break }
                }
            }
            $kept.Reverse()

            [System.IO.File]::WriteAllLines($tmpIndex, $kept.ToArray(), $Utf8NoBom)
            [System.IO.File]::Replace($tmpIndex, $indexPath, $null, $true)

            $script:IndexSet       = $seen
            $script:IndexLoaded    = $true
            $fi = New-Object System.IO.FileInfo($indexPath)
            $script:IndexLastWrite = $fi.LastWriteTimeUtc
            $script:IndexLength    = $fi.Length
            Write-Log ('INDEX COMPACTED: ' + $lines.Count + ' -> ' + $kept.Count + ' entries')
        } catch {
            Write-Log ('INDEX COMPACT ERROR: ' + $_.Exception.Message)
            try { if ([System.IO.File]::Exists($tmpIndex)) { [System.IO.File]::Delete($tmpIndex) } } catch {}
        }
    }

    # ============================================================
    # PER-FILE EXPONENTIAL ERROR BACKOFF
    # ============================================================
    $script:ErrorBackoff = @{}

    function Test-InBackoff([string]$key) {
        if (-not $script:ErrorBackoff.ContainsKey($key)) { return $false }
        return ((Get-Date) -lt $script:ErrorBackoff[$key].NextRetry)
    }

    function Record-FileError([string]$key) {
        $count = 1
        if ($script:ErrorBackoff.ContainsKey($key)) {
            $count = $script:ErrorBackoff[$key].Count + 1
        }
        $delaySec = [Math]::Min(600, [int](30 * [Math]::Pow(2, [Math]::Min($count - 1, 5))))
        $script:ErrorBackoff[$key] = @{
            Count     = $count
            NextRetry = (Get-Date).AddSeconds($delaySec)
        }
    }

    function Clear-FileError([string]$key) {
        if ($script:ErrorBackoff.ContainsKey($key)) {
            $script:ErrorBackoff.Remove($key)
        }
    }

    # ============================================================
    # SAFE ATOMIC COPY (.tmp + integrity check + atomic swap/.bak)
    # ============================================================
    function Safe-CopyFile([string]$srcPath, [string]$destPath) {
        $tmpPath = $destPath + '.tmp'
        $bakPath = $destPath + '.bak'
        try {
            $lpSrc  = ConvertTo-SafePath $srcPath
            $lpDest = ConvertTo-SafePath $destPath
            $lpTmp  = ConvertTo-SafePath $tmpPath
            $lpBak  = ConvertTo-SafePath $bakPath

            if ([System.IO.File]::Exists($lpTmp)) {
                [System.IO.File]::SetAttributes($lpTmp, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($lpTmp)
            }

            $destFolder = [System.IO.Path]::GetDirectoryName($destPath)
            if (-not [string]::IsNullOrEmpty($destFolder)) {
                $lpFolder = ConvertTo-SafePath $destFolder
                if (-not [System.IO.Directory]::Exists($lpFolder)) {
                    [System.IO.Directory]::CreateDirectory($lpFolder) | Out-Null
                }
            }

            $srcBefore      = New-Object System.IO.FileInfo($lpSrc)
            $srcSizeBefore  = $srcBefore.Length
            $srcMtimeBefore = $srcBefore.LastWriteTimeUtc

            [System.IO.File]::Copy($lpSrc, $lpTmp, $true)

            $tmpAttrs = [System.IO.File]::GetAttributes($lpTmp)
            if (($tmpAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($lpTmp, ($tmpAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
            }

            $srcAfter = New-Object System.IO.FileInfo($lpSrc)
            $tmpInfo  = New-Object System.IO.FileInfo($lpTmp)
            if ($srcAfter.Length -ne $srcSizeBefore -or $srcAfter.LastWriteTimeUtc -ne $srcMtimeBefore) {
                throw 'Source file changed during copy; will retry'
            }
            if ($tmpInfo.Length -ne $srcSizeBefore) {
                throw ('Integrity check failed: src=' + $srcSizeBefore + ' bytes, copied=' + $tmpInfo.Length + ' bytes')
            }

            try { [System.IO.File]::SetLastWriteTimeUtc($lpTmp, $srcMtimeBefore) } catch {}

            if ([System.IO.File]::Exists($lpDest)) {
                $destAttrs = [System.IO.File]::GetAttributes($lpDest)
                if (($destAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                    [System.IO.File]::SetAttributes($lpDest, ($destAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                }
                if ([System.IO.File]::Exists($lpBak)) {
                    try {
                        [System.IO.File]::SetAttributes($lpBak, [System.IO.FileAttributes]::Normal)
                        [System.IO.File]::Delete($lpBak)
                    } catch {}
                }
                try {
                    [System.IO.File]::Replace($lpTmp, $lpDest, $lpBak, $true)
                    if ([System.IO.File]::Exists($lpBak)) {
                        try { [System.IO.File]::Delete($lpBak) } catch {}
                    }
                } catch {
                    if ([System.IO.File]::Exists($lpDest) -and -not [System.IO.File]::Exists($lpBak)) {
                        [System.IO.File]::Move($lpDest, $lpBak)
                    }
                    try {
                        [System.IO.File]::Move($lpTmp, $lpDest)
                        if ([System.IO.File]::Exists($lpBak)) {
                            try { [System.IO.File]::Delete($lpBak) } catch {}
                        }
                    } catch {
                        if ([System.IO.File]::Exists($lpBak) -and -not [System.IO.File]::Exists($lpDest)) {
                            try { [System.IO.File]::Move($lpBak, $lpDest) } catch {}
                        }
                        throw
                    }
                }
            } else {
                [System.IO.File]::Move($lpTmp, $lpDest)
            }

            return $true
        } catch {
            Write-Log ('COPY FAILED [' + [System.IO.Path]::GetFileName($srcPath) + ']: ' + $_.Exception.Message)
            try {
                $lpTmpClean = ConvertTo-SafePath $tmpPath
                if ([System.IO.File]::Exists($lpTmpClean)) {
                    [System.IO.File]::SetAttributes($lpTmpClean, [System.IO.FileAttributes]::Normal)
                    [System.IO.File]::Delete($lpTmpClean)
                }
            } catch {}
            return $false
        }
    }

    # ============================================================
    # LEAK-FREE USB DRIVE DISCOVERY (Removable + External USB HDD/SSD)
    # ============================================================
    $script:LastDriveSignature = ''
    $script:CachedUsbDrives    = @()
    $script:TargetNotified     = @{}
    $script:SourceLogged       = @{}

    function Get-ReadyUsbDrives {
        $readyDrives = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
            try { $_.IsReady -and $_.TotalSize -gt 0 } catch { $false }
        })

        $sigParts = New-Object System.Collections.Generic.List[string]
        foreach ($d in $readyDrives) {
            $lbl = ''
            try { $lbl = $d.VolumeLabel } catch {}
            $sigParts.Add($d.Name + '|' + $d.DriveType.ToString() + '|' + $d.TotalSize.ToString() + '|' + $lbl)
        }
        $sig = ($sigParts -join ';')

        if ($sig -eq $script:LastDriveSignature) {
            return $script:CachedUsbDrives
        }

        # Drive topology changed: clear stale error backoffs and target-notification flags for removed drives
        $activeRoots = @($readyDrives | ForEach-Object { $_.Name })
        $staleKeys = @($script:ErrorBackoff.Keys | Where-Object {
            $k = $_
            $match = $false
            foreach ($r in $activeRoots) {
                if ($k.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { $match = $true; break }
            }
            (-not $match) -and (-not $k.StartsWith($DocsDir, [System.StringComparison]::OrdinalIgnoreCase))
        })
        foreach ($sk in $staleKeys) { $script:ErrorBackoff.Remove($sk) }

        $readySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $driveMetaById = @{}
        foreach ($d in $readyDrives) {
            $id = $d.Name.TrimEnd('\').ToUpperInvariant()
            [void]$readySet.Add($id)
            $lbl = ''
            try { $lbl = if ([string]::IsNullOrWhiteSpace($d.VolumeLabel)) { '' } else { $d.VolumeLabel.Trim() } } catch {}
            $driveMetaById[$id] = @{ DriveType = $d.DriveType; Root = $d.Name; Label = $lbl }
        }

        # Clear TargetNotified & SourceLogged entries for unplugged drives
        $staleNotif = @($script:TargetNotified.Keys | Where-Object {
            $did = $_.Split('|')[0]
            -not $readySet.Contains($did)
        })
        foreach ($sn in $staleNotif) { $script:TargetNotified.Remove($sn) }

        $staleSrc = @($script:SourceLogged.Keys | Where-Object {
            $did = $_.Split('|')[0]
            -not $readySet.Contains($did)
        })
        foreach ($ss in $staleSrc) { $script:SourceLogged.Remove($ss) }

        # Fetch Win32_LogicalDisk map once for VolumeSerialNumber lookup
        $cimDiskMap = @{}
        $cimOk = $false
        try {
            $allLogical = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
            foreach ($ld in $allLogical) {
                if (-not [string]::IsNullOrEmpty($ld.DeviceID)) {
                    $cimDiskMap[$ld.DeviceID.ToUpperInvariant()] = $ld
                }
            }
            $cimOk = $true
        } catch {}

        # Map drive letters to physical USB hardware serials
        $hwSerialById = @{}
        $usbFixedIds  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $usbDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "InterfaceType='USB'" -ErrorAction SilentlyContinue)
            foreach ($disk in $usbDisks) {
                $hw = if ($disk.SerialNumber) { $disk.SerialNumber.Trim() } else { '' }
                $parts = @(Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)
                foreach ($part in $parts) {
                    $ldisks = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)
                    foreach ($ld in $ldisks) {
                        if (-not [string]::IsNullOrEmpty($ld.DeviceID)) {
                            $did = $ld.DeviceID.ToUpperInvariant()
                            [void]$usbFixedIds.Add($did)
                            if ($hw -ne '' -and $hw -notmatch '^0+$') { $hwSerialById[$did] = $hw }
                        }
                    }
                }
            }
        } catch {}
        try {
            $msftUsbDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -eq 'USB' })
            foreach ($md in $msftUsbDisks) {
                $hw = if ($md.SerialNumber) { $md.SerialNumber.Trim() } else { '' }
                $mparts = @(Get-Partition -DiskNumber $md.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
                foreach ($mp in $mparts) {
                    $did = $mp.DriveLetter.ToString().ToUpperInvariant() + ':'
                    [void]$usbFixedIds.Add($did)
                    if ($hw -ne '' -and $hw -notmatch '^0+$' -and (-not $hwSerialById.ContainsKey($did))) {
                        $hwSerialById[$did] = $hw
                    }
                }
            }
        } catch {}

        $found = @{}

        # 1. All ready Removable drives directly from DriveInfo
        foreach ($id in $driveMetaById.Keys) {
            if ($id -eq $SystemDriveId) { continue }
            $meta = $driveMetaById[$id]
            if ($meta.DriveType -eq [System.IO.DriveType]::Removable) {
                $ld = $cimDiskMap[$id]
                $serial = if ($ld -and (-not [string]::IsNullOrWhiteSpace($ld.VolumeSerialNumber))) { $ld.VolumeSerialNumber.Trim().ToUpperInvariant() } else { 'NOSERIAL' }
                $label  = if ($ld -and (-not [string]::IsNullOrWhiteSpace($ld.VolumeName))) { $ld.VolumeName.Trim() } else { $meta.Label }
                $found[$id] = [PSCustomObject]@{
                    DeviceID = $id
                    Root     = $meta.Root
                    Serial   = $serial
                    HwSerial = if ($hwSerialById.ContainsKey($id)) { $hwSerialById[$id] } else { '' }
                    Label    = $label
                }
            }
        }

        # 2. External USB Fixed drives (portable USB HDDs / SSDs)
        foreach ($id in $usbFixedIds) {
            if ($id -eq $SystemDriveId -or $found.ContainsKey($id) -or (-not $readySet.Contains($id))) { continue }
            $meta = $driveMetaById[$id]
            $ld   = $cimDiskMap[$id]
            $serial = if ($ld -and (-not [string]::IsNullOrWhiteSpace($ld.VolumeSerialNumber))) { $ld.VolumeSerialNumber.Trim().ToUpperInvariant() } else { 'NOSERIAL' }
            $label  = if ($ld -and (-not [string]::IsNullOrWhiteSpace($ld.VolumeName))) { $ld.VolumeName.Trim() } else { $meta.Label }
            $found[$id] = [PSCustomObject]@{
                DeviceID = $id
                Root     = $meta.Root
                Serial   = $serial
                HwSerial = if ($hwSerialById.ContainsKey($id)) { $hwSerialById[$id] } else { '' }
                Label    = $label
            }
        }

        if ($cimOk) {
            $script:LastDriveSignature = $sig
        }
        $script:CachedUsbDrives = @($found.Values)
        return $script:CachedUsbDrives
    }

    # ============================================================
    # RESOLVE CONSISTENT SOURCE FOLDER BY SERIAL
    # ============================================================
    function Resolve-SourceDestDir([string]$serial, [string]$label) {
        if ($serial -ne 'NOSERIAL' -and [System.IO.Directory]::Exists($DocsDir)) {
            $prefix = $serial + '_'
            try {
                foreach ($sub in [System.IO.Directory]::EnumerateDirectories($DocsDir)) {
                    $name = [System.IO.Path]::GetFileName($sub)
                    if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $sub
                    }
                }
            } catch {}
        }

        $cleanLabel = if ($label -ne '') {
            (($label -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.'))
        } else {
            'NoLabel'
        }
        if ([string]::IsNullOrWhiteSpace($cleanLabel)) { $cleanLabel = 'NoLabel' }
        return (Join-Path $DocsDir ($serial + '_' + $cleanLabel))
    }

    # ---- STARTUP HOUSEKEEPING ----
    Clean-LeftoverTempFiles $DocsDir
    Rotate-Log
    Compact-Index $IndexFile
    Write-Log 'USB Monitor v4.2 STARTED'

    # ============================================================
    # MAIN MONITOR LOOP (polls every 5 seconds)
    # ============================================================
    $loopCount = 0
    while ($true) {
        $loopCount++
        try {
            $drives     = @(Get-ReadyUsbDrives)
            $targetSet  = Load-RuleSet $TargetsFile
            $ignoreSet  = Load-RuleSet $IgnoreFile

            foreach ($drv in $drives) {
                $root   = $drv.Root
                $serial = $drv.Serial
                $label  = $drv.Label

                if (-not [System.IO.Directory]::Exists($root)) { continue }

                # =====================================================
                # IGNORE USB: .syscopy_ignore or ignore.txt
                # =====================================================
                $ignoreMarker = Join-Path $root '.syscopy_ignore'
                if ([System.IO.File]::Exists($ignoreMarker) -or (Test-DriveMatchesRuleSet $drv $ignoreSet)) {
                    continue
                }

                # =====================================================
                # TARGET USB: .syscopy_target OR targets.txt (Serial / HwSerial / LABEL:)
                # =====================================================
                $targetMarker = Join-Path $root '.syscopy_target'
                $hasMarker    = [System.IO.File]::Exists($targetMarker)
                $isTarget     = $hasMarker -or (Test-DriveMatchesRuleSet $drv $targetSet)

                if ($isTarget) {
                    if ($hasMarker) {
                        try {
                            $tmAttrs = [System.IO.File]::GetAttributes($targetMarker)
                            if (($tmAttrs -band [System.IO.FileAttributes]::Hidden) -eq 0) {
                                [System.IO.File]::SetAttributes($targetMarker, ($tmAttrs -bor [System.IO.FileAttributes]::Hidden))
                            }
                        } catch {}
                    }

                    $targetKey      = $drv.DeviceID + '|' + $serial
                    $isFirstConnect = -not $script:TargetNotified.ContainsKey($targetKey)
                    $files          = Get-MatchingFiles $DocsDir $null

                    # Show 1-second "Starting..." toast on initial plug-in (or if new files arrived)
                    if ($isFirstConnect) {
                        Show-BriefToast 'Starting...' 1000 30 90 165
                    }

                    $usbDocsFolder = Join-Path $root 'docs'
                    $moved   = 0
                    $cleaned = 0
                    $errors  = 0

                    foreach ($file in $files) {
                        if (-not [System.IO.Directory]::Exists($root)) {
                            Write-Log ('TARGET | Drive removed mid-transfer: ' + $drv.DeviceID)
                            break
                        }

                        $srcFull = Strip-LongPathPrefix $file.FullName
                        if (Test-InBackoff $srcFull) { continue }

                        $relPath = $srcFull.Substring($DocsDir.Length).TrimStart('\')
                        $dest    = Join-Path $usbDocsFolder $relPath
                        $lpSrc   = ConvertTo-SafePath $srcFull
                        $lpDest  = ConvertTo-SafePath $dest

                        try {
                            $needCopy = $false
                            if (-not [System.IO.File]::Exists($lpDest)) {
                                $needCopy = $true
                            } else {
                                $di = New-Object System.IO.FileInfo($lpDest)
                                $timeDiffSec = ($file.LastWriteTimeUtc - $di.LastWriteTimeUtc).TotalSeconds
                                if ($di.Length -ne $file.Length -or $timeDiffSec -gt 2.0) {
                                    $needCopy = $true
                                }
                            }

                            if ($needCopy) {
                                $ok = Safe-CopyFile $srcFull $dest
                                if (-not $ok) {
                                    Record-FileError $srcFull
                                    $errors++
                                    continue
                                }
                                $srcAttrs = [System.IO.File]::GetAttributes($lpSrc)
                                if (($srcAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                                    [System.IO.File]::SetAttributes($lpSrc, ($srcAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                                }
                                [System.IO.File]::Delete($lpSrc)
                                Clear-FileError $srcFull
                                $moved++
                            } else {
                                $srcAttrs = [System.IO.File]::GetAttributes($lpSrc)
                                if (($srcAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                                    [System.IO.File]::SetAttributes($lpSrc, ($srcAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                                }
                                [System.IO.File]::Delete($lpSrc)
                                Clear-FileError $srcFull
                                $cleaned++
                            }
                        } catch {
                            Write-Log ('TARGET-USB MOVE ERROR [' + $file.Name + ']: ' + $_.Exception.Message)
                            Record-FileError $srcFull
                            $errors++
                        }
                    }

                    if ($moved -gt 0 -or $cleaned -gt 0) {
                        Remove-EmptyDirectories $DocsDir
                        $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { $serial }
                        Write-Log ('TARGET | ' + $displayName + ' | ' + $moved + ' moved, ' + $cleaned + ' already-synced cleaned, ' + $errors + ' errors')
                    } elseif ($errors -gt 0) {
                        $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { $serial }
                        Write-Log ('TARGET | ' + $displayName + ' | 0 moved, ' + $errors + ' errors')
                    }

                    # Show 1-second "OK" toast on initial completion (or if new files were moved)
                    if ($isFirstConnect -or $moved -gt 0 -or $cleaned -gt 0) {
                        if ($errors -eq 0) {
                            Show-BriefToast 'OK' 1000 28 135 72
                        } else {
                            Show-BriefToast ('OK (' + $errors + ' err)') 1000 185 110 20
                        }
                        $script:TargetNotified[$targetKey] = $true
                    }

                } else {
                    # =====================================================
                    # SOURCE USB: copy docs FROM this USB into system (scans all folders including docs\)
                    # =====================================================
                    $destDir = Resolve-SourceDestDir $serial $label
                    Sync-IndexCache $IndexFile

                    $copied  = 0
                    $skipped = 0
                    $errors  = 0

                    $files = Get-MatchingFiles $root $null
                    foreach ($file in $files) {
                        if (-not [System.IO.Directory]::Exists($root)) {
                            Write-Log ('SOURCE | Drive removed mid-scan: ' + $drv.DeviceID)
                            break
                        }

                        $srcFull = Strip-LongPathPrefix $file.FullName
                        if (Test-InBackoff $srcFull) { continue }

                        $relPath = $srcFull.Substring($root.Length).TrimStart('\')
                        $key     = Get-IndexKey $serial $relPath $file

                        if ($script:IndexSet.Contains($key)) {
                            $skipped++
                            continue
                        }

                        $dest   = Join-Path $destDir $relPath
                        $lpDest = ConvertTo-SafePath $dest

                        try {
                            if ([System.IO.File]::Exists($lpDest)) {
                                $destItem = New-Object System.IO.FileInfo($lpDest)
                                $diffSec  = [Math]::Abs(($destItem.LastWriteTimeUtc - $file.LastWriteTimeUtc).TotalSeconds)
                                if ($destItem.Length -eq $file.Length -and $diffSec -le 2.0) {
                                    [void](Add-ToIndex $IndexFile $key)
                                    Clear-FileError $srcFull
                                    $skipped++
                                    continue
                                }
                            }

                            $ok = Safe-CopyFile $srcFull $dest
                            if ($ok) {
                                [void](Add-ToIndex $IndexFile $key)
                                Clear-FileError $srcFull
                                $copied++
                            } else {
                                Record-FileError $srcFull
                                $errors++
                            }
                        } catch {
                            Write-Log ('SOURCE ERROR [' + $file.Name + ']: ' + $_.Exception.Message)
                            Record-FileError $srcFull
                            $errors++
                        }
                    }

                    $sourceKey = $drv.DeviceID + '|' + $serial
                    if ($copied -gt 0 -or $errors -gt 0 -or (-not $script:SourceLogged.ContainsKey($sourceKey))) {
                        $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { 'NoLabel (' + $serial + ')' }
                        $st = $script:LastScanStats
                        Write-Log ('SOURCE | ' + $displayName + ' [' + $root + '] | seen=' + $st.TotalFiles + ' files/' + $st.Dirs + ' dirs (matched=' + $st.Matched + ', docsExcl=' + $st.ExcludedDocs + ', scanErr=' + $st.ScanErrors + ') | ' + $copied + ' NEW copied, ' + $skipped + ' skipped (indexed), ' + $errors + ' errors')
                        $script:SourceLogged[$sourceKey] = $true
                    }
                }
            }

            # Periodic maintenance every ~8 minutes
            if ($loopCount % 100 -eq 0) {
                Rotate-Log
                Compact-Index $IndexFile
            }
        } catch {
            Write-Log ('MONITOR LOOP ERROR: ' + $_.Exception.Message)
        }

        Start-Sleep -Seconds 5
    }
} finally {
    if ($hasMutex -and $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($mutex) { $mutex.Dispose() }
}
'@

Set-Content -LiteralPath $MonitorPS1 -Value $monitorCode -Encoding UTF8

# ---- Silent VBS Launcher (no console flash in interactive session; allows 1s GUI toasts) ----
$vbsCode = @'
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1File = scriptDir & "\usb_monitor.ps1"
If Not fso.FileExists(ps1File) Then WScript.Quit
Set sh = CreateObject("Wscript.Shell")
sh.Run "powershell.exe -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1File & """", 0, False
'@
Set-Content -LiteralPath $LauncherVBS -Value $vbsCode -Encoding ASCII

# ---- Register Scheduled Task (Interactive + Highest so 1-second GUI toasts appear on desktop) ----
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action      = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $LauncherVBS + '"')
$trigger     = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$settings    = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$registered = $false
$regError   = ''

try {
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($trigger) `
        -Settings $settings `
        -Principal $principal `
        -Description 'USB Monitor' `
        -Force | Out-Null
    $registered = $true
} catch {
    $regError = $_.Exception.Message
    try {
        $schArgs = '/create /tn "' + $TaskName + '" /tr "wscript.exe \"' + $LauncherVBS + '\"" /sc ONLOGON /f /rl HIGHEST'
        $p = Start-Process 'schtasks.exe' -ArgumentList $schArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            $registered = $true
            $regError   = ''
        } else {
            $regError = 'schtasks.exe exited with code ' + $p.ExitCode
        }
    } catch {
        $regError = $_.Exception.Message
    }
}

# ---- Start immediately via Task Scheduler ----
$started = $false
if ($registered) {
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $started = $true
    } catch {
        try {
            $pRun = Start-Process 'schtasks.exe' -ArgumentList @('/run', '/tn', $TaskName) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            $started = ($pRun.ExitCode -eq 0)
        } catch {}
    }
}

# ---- Result Message ----
if ($registered) {
    $startNote = if ($started) { 'USB monitor is now running in the background.' } else { 'Task registered; monitor will start automatically at next logon.' }
    $msg  = 'USB installed!' + $nl + $nl
    $msg += $startNote + $nl + $nl
    $msg += 'DESTINATION:' + $nl
    $msg += '  ' + $DocsDir + $nl + $nl
    $msg += 'TARGET USB OPTIONS:' + $nl
    $msg += '  1) Double-click this installer again -> Add Target USB (no file needed on USB)' + $nl
    $msg += '  2) Or place a .syscopy_target file in the USB root' + $nl
    $msg += '  3) Or add Serial / HwSerial / LABEL:Name to ' + $TargetsFile + $nl + $nl
    $msg += 'TARGET NOTIFICATIONS:' + $nl
    $msg += '  - Shows "Starting..." (1s) on connect, then "OK" (1s) when finished.' + $nl + $nl
    $msg += 'LOGS:' + $nl
    $msg += '  ' + $LogFile + $nl + $nl
    $msg += 'To update, add a Target USB, or uninstall: double-click this file again.'
    [System.Windows.Forms.MessageBox]::Show($msg, 'USB - Ready', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show(
        'Installation failed. Please right-click and Run as Administrator.' + $nl + $nl + 'Details: ' + $regError,
        'USB', 'OK', 'Warning'
    ) | Out-Null
}
