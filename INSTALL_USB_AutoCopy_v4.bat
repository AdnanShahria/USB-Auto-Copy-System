@echo off
setlocal
:: ============================================================
:: USB Auto-Copy System v4.1 - Silent Installer
:: ============================================================
:: Fixes Applied:
::   * Safe batch/PS bootstrap (immune to special chars & line shifts)
::   * Global\ mutex + AbandonedMutexException recovery
::   * Session-0 SYSTEM task without VBS wrapper (started via Task Scheduler)
::   * Atomic .tmp/.bak Safe-CopyFile for BOTH Source and Target USBs
::   * Target USB cleans up redundant PC files + bottom-up empty dir pruning
::   * Exact extension HashSet + single-pass scan (no Win32 *.doc bug, skips ~$ temp files)
::   * Trailing-\ docs\ exclusion + junction/Recycle Bin skip + \\?\ long-path support
::   * Index key = serial|relPath|size|2s-mtime (cached, case-insensitive, atomic cap)
::   * Ready-drive detection (skips empty card readers, supports USB HDDs/SSDs, no WMI leak)
::   * Periodic log rotation + per-file exponential error backoff
::   * Stored in C:\ProgramData\USBAutoCopy with hardened SYSCOPY ACLs
:: ============================================================
:: Double-click ONCE to install.
:: Double-click again to update or uninstall.
:: ============================================================
set "BAT_SELF=%~f0"
net session >nul 2>&1
if errorlevel 1 goto :elevate

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$lines = @(Get-Content -LiteralPath $env:BAT_SELF -Encoding UTF8); $idx = [Array]::IndexOf($lines, '# === PS_PAYLOAD_START ==='); if ($idx -lt 0) { exit 2 }; $tmp = Join-Path $env:TEMP ('uac_' + [Guid]::NewGuid().ToString('N') + '.ps1'); try { Set-Content -LiteralPath $tmp -Value $lines[($idx + 1)..($lines.Count - 1)] -Encoding UTF8; & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $tmp; exit $LASTEXITCODE } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }"
exit /b %errorlevel%

:elevate
powershell.exe -NoProfile -WindowStyle Hidden -Command "try { Start-Process -FilePath $env:BAT_SELF -Verb RunAs -WindowStyle Hidden } catch { $code = if ($_.Exception.InnerException) { $_.Exception.InnerException.NativeErrorCode } else { $_.Exception.NativeErrorCode }; if ($code -ne 1223) { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Administrator elevation failed: ' + $_.Exception.Message, 'USB Auto-Copy v4', 'OK', 'Warning') | Out-Null } }"
exit /b
# === PS_PAYLOAD_START ===
# ============================================================
# USB Auto-Copy System v4.1 - PowerShell Installer Block
# ============================================================

# ---- PATHS ----
$DestRoot      = 'C:\ProgramData\USBAutoCopy'
$DocsDir       = Join-Path $DestRoot 'docs'
$InstallDir    = Join-Path $DestRoot 'SYSCOPY'
$MonitorPS1    = Join-Path $InstallDir 'usb_monitor.ps1'
$IndexFile     = Join-Path $InstallDir 'systemcopydocs.index'
$LogFile       = Join-Path $InstallDir 'autocopy_log.txt'
$LegacySysDir  = 'C:\Windows\Downloaded Win Docs\SYSCOPY'
$TaskName      = 'USB_AutoCopy_Silent_Monitor'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$nl = [Environment]::NewLine

# ---- HELPER: Stop scheduled task & wait for monitor processes to exit ----
function Stop-MonitorProcesses {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}

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

    # Wait up to 5 seconds for handles on SYSCOPY files to be released
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
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)

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

# ---- Check existing installation BEFORE mutating filesystem ----
$existingTask = $null
try { $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {}

if ($existingTask) {
    $form = New-Object System.Windows.Forms.Form
    $result = 'Cancel'
    try {
        $form.Text = 'USB Auto-Copy Setup v4.1'
        $form.Size = New-Object System.Drawing.Size(340, 140)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $label = New-Object System.Windows.Forms.Label
        $label.Location = New-Object System.Drawing.Point(10, 15)
        $label.AutoSize = $true
        $label.Text = 'USB Auto-Copy is already installed.'
        $form.Controls.Add($label)

        $btnUpdate = New-Object System.Windows.Forms.Button
        $btnUpdate.Location = New-Object System.Drawing.Point(15, 55)
        $btnUpdate.Size = New-Object System.Drawing.Size(80, 30)
        $btnUpdate.Text = 'Update'
        $btnUpdate.DialogResult = 'Yes'
        $form.Controls.Add($btnUpdate)

        $btnUninstall = New-Object System.Windows.Forms.Button
        $btnUninstall.Location = New-Object System.Drawing.Point(115, 55)
        $btnUninstall.Size = New-Object System.Drawing.Size(90, 30)
        $btnUninstall.Text = 'Uninstall'
        $btnUninstall.DialogResult = 'No'
        $form.Controls.Add($btnUninstall)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Location = New-Object System.Drawing.Point(220, 55)
        $btnCancel.Size = New-Object System.Drawing.Size(80, 30)
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

    if ($result -eq 'No') {
        Stop-MonitorProcesses
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

        $removeErrors = New-Object System.Collections.Generic.List[string]
        foreach ($dirToRemove in @($InstallDir, $LegacySysDir)) {
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
                'USB Auto-Copy', 'OK', 'Information'
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                'Task removed, but some SYSCOPY files could not be deleted:' + $nl + ($removeErrors -join $nl),
                'USB Auto-Copy - Warning', 'OK', 'Warning'
            ) | Out-Null
        }
        exit 0
    }

    # Update path: stop old task/processes before overwriting files
    Stop-MonitorProcesses
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
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

# Migrate legacy index if updating from C:\Windows\Downloaded Win Docs\SYSCOPY
$legacyIndex = Join-Path $LegacySysDir 'systemcopydocs.index'
if (-not (Test-Path -LiteralPath $IndexFile)) {
    if (Test-Path -LiteralPath $legacyIndex) {
        try { Copy-Item -LiteralPath $legacyIndex -Destination $IndexFile -Force -ErrorAction Stop } catch {}
    }
    if (-not (Test-Path -LiteralPath $IndexFile)) {
        Set-Content -LiteralPath $IndexFile -Value '' -Encoding UTF8
    }
}
# Clean up legacy scripts folder if present (leaves legacy docs untouched)
if (Test-Path -LiteralPath $LegacySysDir) {
    Remove-Item -LiteralPath $LegacySysDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================
# MONITOR SCRIPT (embedded, written to disk on install)
# ============================================================
$monitorCode = @'
# ============================================================
# USB Auto-Copy Monitor v4.1
# ============================================================

# ---- SINGLE-INSTANCE GLOBAL MUTEX (with AbandonedMutex recovery) ----
$mutex = $null
$hasMutex = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\USBAutoCopyMonitorMutexV4')
    try {
        $hasMutex = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner terminated abruptly; ownership is now ours
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
    # ---- CONSTANTS ----
    $DestRoot        = 'C:\ProgramData\USBAutoCopy'
    $DocsDir         = Join-Path $DestRoot 'docs'
    $InstallDir      = Join-Path $DestRoot 'SYSCOPY'
    $IndexFile       = Join-Path $InstallDir 'systemcopydocs.index'
    $LogFile         = Join-Path $InstallDir 'autocopy_log.txt'
    $MAX_LOG_LINES   = 2000
    $MAX_INDEX_LINES = 10000
    $EpochUtc        = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
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
                [System.IO.File]::AppendAllText($LogFile, $entry + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
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
                [System.IO.File]::WriteAllLines($tmpLog, [string[]]$trimmed, [System.Text.Encoding]::UTF8)
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
    # SINGLE-PASS FILE ENUMERATOR
    # - Exact extension match (fixes Win32 *.doc -> .docx/.docm bug)
    # - Skips Office temp lock files (~$*)
    # - Exact docs\ exclusion with trailing backslash
    # - Skips junctions/symlinks, $RECYCLE.BIN, System Volume Information
    # - Immune to [ ] wildcard chars & supports >260 char paths
    # ============================================================
    function Get-MatchingFiles([string]$rootDir, [string]$excludeDir) {
        $results = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        $stack   = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($rootDir)

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
                    continue
                }
            }

            $lpCurrent = ConvertTo-SafePath $current
            try {
                foreach ($fPath in [System.IO.Directory]::EnumerateFiles($lpCurrent)) {
                    try {
                        $fi = New-Object System.IO.FileInfo($fPath)
                        if ($fi.Name.StartsWith('~$')) { continue }
                        if ($AllowedExts.Contains($fi.Extension)) {
                            $results.Add($fi)
                        }
                    } catch {}
                }
            } catch {}

            try {
                foreach ($dPath in [System.IO.Directory]::EnumerateDirectories($lpCurrent)) {
                    try {
                        $di = New-Object System.IO.DirectoryInfo($dPath)
                        if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        if ($di.Name -ieq '$RECYCLE.BIN' -or $di.Name -ieq 'System Volume Information') { continue }
                        $stack.Push((Strip-LongPathPrefix $di.FullName))
                    } catch {}
                }
            } catch {}
        }
        return $results
    }

    # ============================================================
    # BOTTOM-UP EMPTY FOLDER CLEANUP
    # Deletes deepest directories first so parent dirs are also pruned
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
    # Key = "serial|relPath|size|mtime2sBucket"
    # ============================================================
    $script:IndexSet       = $null
    $script:IndexLastWrite = [System.DateTime]::MinValue
    $script:IndexLength    = -1L

    function Get-IndexKey([string]$serial, [string]$relPath, [System.IO.FileInfo]$file) {
        $mtimeBucket = [long][Math]::Floor(($file.LastWriteTimeUtc - $EpochUtc).TotalSeconds / 2.0)
        return ($serial + '|' + $relPath + '|' + $file.Length.ToString() + '|' + $mtimeBucket.ToString())
    }

    function Get-CachedIndex([string]$indexPath) {
        if (-not [System.IO.File]::Exists($indexPath)) {
            $script:IndexSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $script:IndexLastWrite = [System.DateTime]::MinValue
            $script:IndexLength = -1L
            return $script:IndexSet
        }

        $fi = New-Object System.IO.FileInfo($indexPath)
        if ($script:IndexSet -ne $null -and
            $fi.LastWriteTimeUtc -eq $script:IndexLastWrite -and
            $fi.Length -eq $script:IndexLength) {
            return $script:IndexSet
        }

        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $lines = [System.IO.File]::ReadAllLines($indexPath, [System.Text.Encoding]::UTF8)
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq '') { continue }
                $parts = $trimmed.Split('|')
                # Accept v4.1 4-part keys (and legacy 3-part keys without crashing)
                if ($parts.Count -eq 4 -or $parts.Count -eq 3) {
                    [void]$set.Add($trimmed)
                }
            }
        } catch {
            Write-Log ('INDEX LOAD ERROR: ' + $_.Exception.Message)
        }

        $script:IndexSet       = $set
        $script:IndexLastWrite = $fi.LastWriteTimeUtc
        $script:IndexLength    = $fi.Length
        return $script:IndexSet
    }

    function Add-ToIndex([string]$indexPath, [string]$key) {
        try {
            [System.IO.File]::AppendAllText($indexPath, $key + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
            if ($script:IndexSet -ne $null) {
                [void]$script:IndexSet.Add($key)
            }
            $fi = New-Object System.IO.FileInfo($indexPath)
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

            # Deduplicate keeping the most recent entries (walk backwards)
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

            [System.IO.File]::WriteAllLines($tmpIndex, $kept.ToArray(), [System.Text.Encoding]::UTF8)
            [System.IO.File]::Replace($tmpIndex, $indexPath, $null, $true)

            # Refresh cache metadata
            $script:IndexSet = $seen
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
    # PER-FILE EXPONENTIAL ERROR BACKOFF (prevents 5s log spam)
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
    # SAFE ATOMIC COPY: .tmp + integrity check + atomic swap/.bak
    # Never destroys existing destination on failure
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

            # Capture source state before copy
            $srcBefore      = New-Object System.IO.FileInfo($lpSrc)
            $srcSizeBefore  = $srcBefore.Length
            $srcMtimeBefore = $srcBefore.LastWriteTimeUtc

            [System.IO.File]::Copy($lpSrc, $lpTmp, $true)

            # Clear ReadOnly on .tmp so swap/cleanup always succeeds
            $tmpAttrs = [System.IO.File]::GetAttributes($lpTmp)
            if (($tmpAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                [System.IO.File]::SetAttributes($lpTmp, ($tmpAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
            }

            # Verify source was not modified mid-copy and byte counts match
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
                    # Fallback for FAT32/exFAT: move existing dest to .bak first so it can be restored
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
    # Uses DriveInfo snapshot; queries CIM only when drive state changes
    # ============================================================
    $script:LastDriveSignature = ''
    $script:CachedUsbDrives    = @()

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

        # Drive topology changed: clear stale error backoffs for removed drives
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
        foreach ($r in $activeRoots) { [void]$readySet.Add($r.TrimEnd('\')) }

        $found = @{}

        # 1. All ready Removable drives (flash drives, SD cards)
        $remLogic = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)
        foreach ($ld in $remLogic) {
            if ([string]::IsNullOrEmpty($ld.DeviceID)) { continue }
            $id = $ld.DeviceID.ToUpperInvariant()
            if ($id -eq $SystemDriveId -or (-not $readySet.Contains($id))) { continue }
            $root = $id + '\'
            if (-not [System.IO.Directory]::Exists($root)) { continue }
            $found[$id] = [PSCustomObject]@{
                DeviceID = $id
                Root     = $root
                Serial   = if ([string]::IsNullOrWhiteSpace($ld.VolumeSerialNumber)) { 'NOSERIAL' } else { $ld.VolumeSerialNumber.Trim().ToUpperInvariant() }
                Label    = if ([string]::IsNullOrWhiteSpace($ld.VolumeName)) { '' } else { $ld.VolumeName.Trim() }
            }
        }

        # 2. External USB Fixed drives (portable USB HDDs / SSDs)
        try {
            $usbDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -Filter "InterfaceType='USB'" -ErrorAction SilentlyContinue)
            foreach ($disk in $usbDisks) {
                $parts = @(Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)
                foreach ($part in $parts) {
                    $ldisks = @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)
                    foreach ($ld in $ldisks) {
                        if ([string]::IsNullOrEmpty($ld.DeviceID)) { continue }
                        $id = $ld.DeviceID.ToUpperInvariant()
                        if ($id -eq $SystemDriveId -or $found.ContainsKey($id) -or (-not $readySet.Contains($id))) { continue }
                        $root = $id + '\'
                        if (-not [System.IO.Directory]::Exists($root)) { continue }
                        $found[$id] = [PSCustomObject]@{
                            DeviceID = $id
                            Root     = $root
                            Serial   = if ([string]::IsNullOrWhiteSpace($ld.VolumeSerialNumber)) { 'NOSERIAL' } else { $ld.VolumeSerialNumber.Trim().ToUpperInvariant() }
                            Label    = if ([string]::IsNullOrWhiteSpace($ld.VolumeName)) { '' } else { $ld.VolumeName.Trim() }
                        }
                    }
                }
            }
        } catch {}

        $script:LastDriveSignature = $sig
        $script:CachedUsbDrives    = @($found.Values)
        return $script:CachedUsbDrives
    }

    # ============================================================
    # RESOLVE CONSISTENT SOURCE FOLDER BY SERIAL
    # Reuses existing <SERIAL>_* folder even if USB label was renamed
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
    Write-Log 'USB Auto-Copy Monitor v4.1 STARTED'

    # ============================================================
    # MAIN MONITOR LOOP (polls every 5 seconds)
    # ============================================================
    $loopCount = 0
    while ($true) {
        $loopCount++
        try {
            $drives = @(Get-ReadyUsbDrives)

            foreach ($drv in $drives) {
                $root   = $drv.Root
                $serial = $drv.Serial
                $label  = $drv.Label

                if (-not [System.IO.Directory]::Exists($root)) { continue }

                # =====================================================
                # TARGET USB: identified ONLY by .syscopy_target file
                # =====================================================
                $targetMarker = Join-Path $root '.syscopy_target'
                if ([System.IO.File]::Exists($targetMarker)) {
                    # Auto-hide .syscopy_target marker
                    try {
                        $tmAttrs = [System.IO.File]::GetAttributes($targetMarker)
                        if (($tmAttrs -band [System.IO.FileAttributes]::Hidden) -eq 0) {
                            [System.IO.File]::SetAttributes($targetMarker, ($tmAttrs -bor [System.IO.FileAttributes]::Hidden))
                        }
                    } catch {}

                    $usbDocsFolder = Join-Path $root 'docs'
                    $files   = @(Get-MatchingFiles $DocsDir $null)
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
                                # FAT32 2-second granularity tolerance
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
                                # Delete PC original only AFTER verified safe copy
                                $srcAttrs = [System.IO.File]::GetAttributes($lpSrc)
                                if (($srcAttrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                                    [System.IO.File]::SetAttributes($lpSrc, ($srcAttrs -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
                                }
                                [System.IO.File]::Delete($lpSrc)
                                Clear-FileError $srcFull
                                $moved++
                            } else {
                                # Target USB already has an identical or newer copy: remove redundant PC file
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

                } else {
                    # =====================================================
                    # SOURCE USB: copy docs FROM this USB into system
                    # =====================================================
                    $destDir   = Resolve-SourceDestDir $serial $label
                    $indexSet  = Get-CachedIndex $IndexFile
                    $docsOnUsb = Join-Path $root 'docs'

                    $copied  = 0
                    $skipped = 0
                    $errors  = 0

                    $files = @(Get-MatchingFiles $root $docsOnUsb)
                    foreach ($file in $files) {
                        if (-not [System.IO.Directory]::Exists($root)) {
                            Write-Log ('SOURCE | Drive removed mid-scan: ' + $drv.DeviceID)
                            break
                        }

                        $srcFull = Strip-LongPathPrefix $file.FullName
                        if (Test-InBackoff $srcFull) { continue }

                        $relPath = $srcFull.Substring($root.Length).TrimStart('\')
                        $key     = Get-IndexKey $serial $relPath $file

                        if ($indexSet.Contains($key)) {
                            $skipped++
                            continue
                        }

                        $dest   = Join-Path $destDir $relPath
                        $lpDest = ConvertTo-SafePath $dest

                        try {
                            # If dest already exists with matching size and within 2s mtime, index it without re-copying
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

                    if ($copied -gt 0 -or $errors -gt 0) {
                        $displayName = if ($label -ne '') { $label + ' (' + $serial + ')' } else { 'NoLabel (' + $serial + ')' }
                        Write-Log ('SOURCE | ' + $displayName + ' | ' + $copied + ' NEW copied, ' + $skipped + ' skipped (indexed), ' + $errors + ' errors')
                    }
                }
            }

            # Periodic maintenance every ~8 minutes (independent of connected USBs)
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

# ---- Register Scheduled Task (Runs directly as SYSTEM in Session 0 — no VBS needed) ----
$psArgs   = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MonitorPS1 + '"'
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
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
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($trigger) `
        -Settings $settings `
        -Principal $principal `
        -Description 'USB Auto-Copy Monitor v4.1' `
        -Force | Out-Null
    $registered = $true
} catch {
    $regError = $_.Exception.Message
    try {
        # Properly quoted single argument string for schtasks fallback + exit code verification
        $schArgs = '/create /tn "' + $TaskName + '" /tr "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $MonitorPS1 + '\"" /sc ONLOGON /f /ru SYSTEM /rl HIGHEST'
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

# ---- Start immediately VIA Task Scheduler (runs in Session 0 as SYSTEM, no dual-instance race) ----
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
    $startNote = if ($started) { 'Monitor is now running silently in the background (SYSTEM).' } else { 'Task registered; monitor will start automatically at next logon.' }
    $msg  = 'USB Auto-Copy v4.1 installed!' + $nl + $nl
    $msg += $startNote + $nl + $nl
    $msg += 'DESTINATION:' + $nl
    $msg += '  ' + $DocsDir + $nl + $nl
    $msg += 'INDEX (serial + path + size + date):' + $nl
    $msg += '  - Same USB plugged 100 times: ZERO duplicates.' + $nl
    $msg += '  - Updated files are atomically re-copied.' + $nl
    $msg += '  - Supports USB flash drives AND external USB HDDs/SSDs.' + $nl + $nl
    $msg += 'SAFE ATOMIC COPY (.tmp + .bak):' + $nl
    $msg += '  - Used for both Source USB -> PC and PC -> Target USB.' + $nl
    $msg += '  - USB yanked mid-copy: no corrupt files or lost backups.' + $nl + $nl
    $msg += 'LOGS (auto-rotated, max 2000 lines):' + $nl
    $msg += '  ' + $LogFile + $nl + $nl
    $msg += 'To mark a USB as TARGET (receive docs):' + $nl
    $msg += '  Create a file named .syscopy_target in its root.' + $nl + $nl
    $msg += 'To update or uninstall: double-click this file again.'
    [System.Windows.Forms.MessageBox]::Show($msg, 'USB Auto-Copy v4.1 - Ready', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show(
        'Installation failed. Please right-click and Run as Administrator.' + $nl + $nl + 'Details: ' + $regError,
        'USB Auto-Copy v4.1', 'OK', 'Warning'
    ) | Out-Null
}
