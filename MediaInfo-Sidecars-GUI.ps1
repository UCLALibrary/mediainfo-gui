# MediaInfo Sidecar Generator
# -------------------------------------------------------------------
# 1. DISCOVERY: Robocopy (Bypasses Enumeration limits)
# 2. PARSING: String Manipulation (Bypasses Path class limits)
# 3. KERNEL IO: Direct Windows calls for File/Folder creation
# 4. VALIDATION: Suspends processing on missing frames
# 5. STATUS: Reports "Done with Errors" if issues occurred
# 6. GUI: Fixed truncated checkbox labels
# -------------------------------------------------------------------
$VERSION = "v2.2.2"
$SecondaryJsonDir = "C:\NDM SIdecars"

# Ensure WinForms runs in STA
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = $null
    try { $exe = (Get-Command pwsh -ErrorAction Stop).Source }
    catch { $exe = (Get-Command powershell).Source }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    [void][Diagnostics.Process]::Start($psi)
    exit
}

# -------------------------------------------------------------------
# NATIVE KERNEL METHODS
# -------------------------------------------------------------------
    $nativeCode = @"
    using System;
    using System.Runtime.InteropServices;
    using Microsoft.Win32.SafeHandles;
    using System.IO;

    public class NativeKernelIO {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CreateDirectory(string lpPathName, IntPtr lpSecurityAttributes);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile
        );
    }
"@

Add-Type -TypeDefinition $nativeCode

# -------------------------------------------------------------------
# HELPER: Write Text using Kernel Handle
# -------------------------------------------------------------------
function Write-NativeText {
    param([string]$Path, [string]$Content)
    
    $GENERIC_WRITE = 0x40000000; $CREATE_ALWAYS = 2; $FILE_ATTRIBUTE_NORMAL = 0x80
    $handle = [NativeKernelIO]::CreateFile($Path, $GENERIC_WRITE, 0, [IntPtr]::Zero, $CREATE_ALWAYS, $FILE_ATTRIBUTE_NORMAL, [IntPtr]::Zero)
    
    if ($handle.IsInvalid) { throw "NativeKernelIO error writing to $Path" }

    try {
        $fs = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Write)
        $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        $sw.Write($Content)
        $sw.Flush()
    }
    finally { if ($sw) { $sw.Close() } elseif ($handle) { $handle.Close() } }
}

# Enable .NET Long Path Switches
[System.AppContext]::SetSwitch("Switch.System.IO.UseLegacyPathHandling", $false)
[System.AppContext]::SetSwitch("Switch.System.IO.BlockLongPaths", $false)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# GUI Colors & Fonts
$ColorBackground = [System.Drawing.Color]::FromArgb(245,245,247)
$ColorCard       = [System.Drawing.Color]::FromArgb(252,252,253)
$ColorBorder     = [System.Drawing.Color]::FromArgb(220,223,230)
$ColorText       = [System.Drawing.Color]::FromArgb(33,37,41)
$ColorPrimary    = [System.Drawing.Color]::FromArgb(0,120,215)
$ColorPrimaryDark= [System.Drawing.Color]::FromArgb(0,93,168)
$fontNormal      = New-Object System.Drawing.Font("Segoe UI", 10)
$fontMono        = New-Object System.Drawing.Font("Consolas", 10)

function Style-SecondaryButton($btn) {
    $btn.Font = $fontNormal; 
    $btn.FlatStyle = 'Flat'; 
    $btn.FlatAppearance.BorderColor = $ColorBorder; 
    $btn.FlatAppearance.BorderSize  = 1; 
    $btn.BackColor = [System.Drawing.Color]::FromArgb(236,239,244); 
    $btn.ForeColor = $ColorText; 
    $btn.UseVisualStyleBackColor = $false
}
function Style-PrimaryButton($btn) {
    $btn.Font = $fontNormal; 
    $btn.FlatStyle = 'Flat'; 
    $btn.FlatAppearance.BorderColor = $ColorPrimaryDark; 
    $btn.FlatAppearance.BorderSize  = 1; 
    $btn.BackColor = $ColorPrimary; 
    $btn.ForeColor = [System.Drawing.Color]::White; 
    $btn.UseVisualStyleBackColor = $false
}

# -------------------------------------------------------------------
# SAFE STRING MANIPULATION
# -------------------------------------------------------------------

function Get-SafeDirectoryName([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return "" }
    $idx = $path.LastIndexOf('\')
    if ($idx -le 0) { return $path } 
    return $path.Substring(0, $idx)
}

function Get-SafeFileName([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return "" }
    $idx = $path.LastIndexOf('\')
    if ($idx -lt 0) { return $path }
    return $path.Substring($idx + 1)
}

function Get-LongPath([string]$Path) {
    $Path = $Path.TrimEnd('\')
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return "\\?\UNC\" + $Path.Substring(2).TrimStart('\') }
    return "\\?\$Path"
}

function Get-PathParts([string]$longPath) {
    $nonPrefixPath = $longPath
    if ($longPath.StartsWith('\\?\')) {
        $nonPrefixPath = $longPath.Substring(4)
        if ($nonPrefixPath.StartsWith('UNC\')) { $nonPrefixPath = '\\' + $nonPrefixPath.Substring(4) }
    }
    
    $fileName = Get-SafeFileName $nonPrefixPath
    $dirName  = Get-SafeDirectoryName $nonPrefixPath
    
    return [PSCustomObject]@{
        LongPath      = $longPath
        LongPathDir   = Get-LongPath $dirName
        NonPrefixDir  = $dirName
        NonPrefixFile = $fileName
        NonPrefixFull = $nonPrefixPath
    }
}

# -------------------------------------------------------------------
# ROBOCOPY DISCOVERY
# -------------------------------------------------------------------
function Get-FilesWithRobocopy {
    param([string]$Source, [string[]]$Masks, [bool]$Recurse)
    $sourcePath = $Source.TrimEnd('\')

    if ($sourcePath -match '^[A-Za-z]:$') {
        $sourcePath += '\'
    }

    $quotedSource = if ($sourcePath.EndsWith('\')) { "`"$sourcePath\`"" } else { "`"$sourcePath`"" }

    $args = @($quotedSource, "NULL") + $Masks
    $args += "/L", "/FP", "/NJH", "/NJS", "/NC", "/NS", "/NDL", "/NP", "/R:0", "/W:0", "/XD", '"System Volume Information"', '"$RECYCLE.BIN"', '".Trashes"'
    if ($Recurse) { $args += "/E" }


    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = "robocopy.exe"
    $pInfo.Arguments = $args -join " "
    $pInfo.RedirectStandardOutput = $true
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true
    
    $p = [System.Diagnostics.Process]::Start($pInfo)
    $output = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()

    $files = @()
    if ($output) {
        $lines = $output -split "`r`n"
        foreach ($line in $lines) {
            $trim = $line.Trim()
            if ($trim.Length -gt 0) {
                $files += Get-LongPath $trim
            }
        }
    }
    return $files
}

# Logging & Tools ----------------------------------------------------
function Write-Log($msg) {
    $rtbLog.AppendText("$msg`r`n")
    $rtbLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-MediaInfoPath {
    try { return (Get-Command mediainfo.exe -ErrorAction Stop).Source }
    catch {
        $paths = @("C:\Program Files\MediaInfo\MediaInfo.exe","C:\Program Files (x86)\MediaInfo\MediaInfo.exe","C:\MediaInfo CLI\MediaInfo.exe","C:\MediaInfo\MediaInfo.exe")
        foreach ($p in $paths) { if (Test-Path $p) { return $p } }
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Locate mediainfo.exe"; $ofd.Filter = "MediaInfo|mediainfo.exe"
        if ($ofd.ShowDialog() -eq "OK") { return $ofd.FileName }
        return $null
    }
}

$AppDir = Join-Path $env:APPDATA 'MediaInfoSidecars'; $MaskFile = Join-Path $AppDir 'masks.json'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
$DefaultMasks = @(
  '*.3g2','*.3gp','*.aac','*.aiff','*.aif','*.amv','*.asf','*.avi','*.dpx','*.f4v','*.flac','*.flv','*.gifv','*.m2ts',
  '*.m4a','*.m4v','*.mkv','*.mng','*.mov','*.mp3','*.mp4','*.mpg','*.mpeg','*.mts','*.mxf','*.nsv','*.ogg','*.rm',
  '*.rmvb','*.roq','*.srt','*.svi','*.ts','*.viv','*.vob','*.vtt','*.wav','*.webm','*.wma','*.wmv','*.yuv'
)

function Load-Masks {
    if (Test-Path $MaskFile) {
        try {
            $j = Get-Content -Raw -LiteralPath $MaskFile | ConvertFrom-Json

            if ($j.masks) {
                return $j.masks
            }
        }
        catch {
        }
    }

    return $DefaultMasks
}

function Save-Masks([string[]]$m) {
    [pscustomobject]@{
        masks = $m
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath $MaskFile -Encoding UTF8
}

# GUI Layout ---------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "MediaInfo Sidecar Generator - " + $VERSION; 
$form.Size = '870,720'; 
$form.BackColor = $ColorBackground; 
$form.StartPosition = 'CenterScreen'; 
$form.Font = $fontNormal

$lblFolder = New-Object System.Windows.Forms.Label; 
$lblFolder.Text = "Source folder:"; 
$lblFolder.Location = '14,18'; 
$lblFolder.AutoSize = $true
$txtFolder = New-Object System.Windows.Forms.TextBox; 
$txtFolder.Location = '120,15'; 
$txtFolder.Size = '610,26'; 
$txtFolder.ReadOnly = $true
$btnBrowse = New-Object System.Windows.Forms.Button; 
$btnBrowse.Text = "Browse"; 
$btnBrowse.Location = '740,13'; 
$btnBrowse.Size = '96,30'; 
Style-SecondaryButton $btnBrowse
$btnBrowse.Add_Click({
    $f = New-Object System.Windows.Forms.FolderBrowserDialog

    if ($f.ShowDialog() -eq "OK") {
        $txtFolder.Text = $f.SelectedPath
    }
})

$grpFormat = New-Object System.Windows.Forms.GroupBox
$grpFormat.Text = "Output format"
$grpFormat.Location = '14,58'
$grpFormat.Size = '410,100'

$rbTxt = New-Object System.Windows.Forms.RadioButton
$rbTxt.Text = "Text"
$rbTxt.Location = '18,30'

$rbJson = New-Object System.Windows.Forms.RadioButton
$rbJson.Text = "JSON"
$rbJson.Location = '200,30'
$rbJson.Checked = $true

$rbXml = New-Object System.Windows.Forms.RadioButton
$rbXml.Text = "XML"
$rbXml.Location = '18,58'

$grpFormat.Controls.AddRange(
    @(
        $rbTxt
        $rbJson
        $rbXml
    )
)

# -------------------------------------------------------------------
# GUI FIX: Increased Size and Added AutoSize for Checkboxes
# -------------------------------------------------------------------
$chkRecurse = New-Object System.Windows.Forms.CheckBox
$chkRecurse.Text = "Recurse subfolders"
$chkRecurse.Checked = $true
$chkRecurse.Location = '440,68'
$chkRecurse.AutoSize = $true  # Fix truncation

$chkSidecarsSub = New-Object System.Windows.Forms.CheckBox
$chkSidecarsSub.Text = "Place sidecars in 'sidecars' subfolder"
$chkSidecarsSub.Checked = $true
$chkSidecarsSub.Location = '440,95'
$chkSidecarsSub.AutoSize = $true  # Fix truncation

$grpMasks = New-Object System.Windows.Forms.GroupBox
$grpMasks.Text = "File masks"
$grpMasks.Location = '14,168'
$grpMasks.Size = '822,260'

$lstMasks = New-Object System.Windows.Forms.ListBox
$lstMasks.Location = '18,28'
$lstMasks.Size = '540,200'

$btnAddMask = New-Object System.Windows.Forms.Button
$btnAddMask.Text = "Add"
$btnAddMask.Location = '580,28'
$btnAddMask.Size = '160,34'
Style-SecondaryButton $btnAddMask

$btnRemoveMask = New-Object System.Windows.Forms.Button
$btnRemoveMask.Text = "Remove selected"
$btnRemoveMask.Location = '580,72'
$btnRemoveMask.Size = '160,34'
Style-SecondaryButton $btnRemoveMask

$btnResetDefaults = New-Object System.Windows.Forms.Button
$btnResetDefaults.Text = "Reset to defaults"
$btnResetDefaults.Location = '580,116'
$btnResetDefaults.Size = '160,34'
Style-SecondaryButton $btnResetDefaults

$btnSaveMasks = New-Object System.Windows.Forms.Button
$btnSaveMasks.Text = "Save masks"
$btnSaveMasks.Location = '580,160'
$btnSaveMasks.Size = '160,34'
Style-PrimaryButton $btnSaveMasks

$lblMaskHint = New-Object System.Windows.Forms.Label
$lblMaskHint.Text = "Masks stored in %APPDATA%\MediaInfoSidecars\masks.json"
$lblMaskHint.Location = '18,232'
$lblMaskHint.AutoSize = $true

$grpMasks.Controls.AddRange(
    @(
        $lstMasks
        $btnAddMask
        $btnRemoveMask
        $btnResetDefaults
        $btnSaveMasks
        $lblMaskHint
    )
)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Generate sidecars"
$btnRun.Location = '14,442'
$btnRun.Size = '822,44'
Style-PrimaryButton $btnRun

$prg = New-Object System.Windows.Forms.ProgressBar
$prg.Location = '14,496'
$prg.Size = '822,22'

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = '14,524'
$rtbLog.Size = '822,130'
$rtbLog.Font = $fontMono
$rtbLog.ReadOnly = $true
$rtbLog.BackColor = $ColorCard

$form.Controls.AddRange(
    @(
        $lblFolder
        $txtFolder
        $btnBrowse
        $grpFormat
        $chkRecurse
        $chkSidecarsSub
        $grpMasks
        $btnRun
        $prg
        $rtbLog
    )
)

$Global:Masks = Load-Masks
$lstMasks.Items.AddRange($Global:Masks)

$btnAddMask.Add_Click({
    $m = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Add mask",
        "Add",
        "*.ext"
    )

    if (
        $m -and
        $m.Trim() -ne "" -and
        $lstMasks.Items -notcontains $m
    ) {
        $lstMasks.Items.Add($m)
    }
})

$btnRemoveMask.Add_Click({
    foreach ($x in @($lstMasks.SelectedItems)) {
        $lstMasks.Items.Remove($x)
    }
})

$btnResetDefaults.Add_Click({
    $lstMasks.Items.Clear()
    $lstMasks.Items.AddRange($DefaultMasks)
})

$btnSaveMasks.Add_Click({
    $Global:Masks = @()

    foreach ($i in $lstMasks.Items) {
        $Global:Masks += [string]$i
    }

    Save-Masks $Global:Masks
    Write-Log "Masks saved."
})

# -------------------------------------------------------------------
# RUN LOGIC
# -------------------------------------------------------------------

$btnRun.Add_Click({
    $rtbLog.Clear()
    if (-not (Test-Path $txtFolder.Text)) { [Windows.Forms.MessageBox]::Show("Select a valid folder."); return }
    $mediainfoPath = Get-MediaInfoPath
    if (-not $mediainfoPath) { [Windows.Forms.MessageBox]::Show("Cannot locate mediainfo.exe"); return }

    $curMasks = @(); foreach ($i in $lstMasks.Items) { $curMasks += [string]$i }

    Write-Log "Using MediaInfo: $mediainfoPath"
    Write-Log "Scanning: $($txtFolder.Text)"
    
    $globalHasErrors = $false

    # 1. DISCOVERY via Robocopy
    Write-Log "Enumerating files using Robocopy (Long Path Safe)..."
    [System.Windows.Forms.Application]::DoEvents()
    
    $rawSource = $txtFolder.Text

    try {
        $foundFiles = @(
            Get-FilesWithRobocopy `
                -Source $rawSource `
                -Masks $curMasks `
                -Recurse $chkRecurse.Checked
        )
    }
    catch {
        $globalHasErrors = $true
        Write-Log "ERROR: File enumeration failed."
        Write-Log $_.Exception.Message
        Write-Log "`r`nDone with Errors."
        return
    }
    
    if ($foundFiles.Count -eq 0) { Write-Log "No files found."; return }

    # 2. SEPARATION & GROUPING
    $dpxGroups = @{} 
    $filesToProcess = @()
    
    foreach ($file in $foundFiles) {
        if ($file.EndsWith(".dpx", [System.StringComparison]::OrdinalIgnoreCase)) {
            $dirName = Get-SafeDirectoryName $file
            if (-not $dpxGroups.ContainsKey($dirName)) {
                $dpxGroups[$dirName] = @()
            }
            $dpxGroups[$dirName] += $file
        } else {
            $filesToProcess += $file
        }
    }

    # 3. DPX VALIDATION LOGIC
    #
    # Each directory is expected to contain at most one DPX image sequence.
    # Valid sequence filenames must end with a 4-8 digit frame number before .dpx.
    # The sequence prefix may be empty or contain any characters.
    # The sequence may start at any frame number.
    #
    # Examples:
    #   0001.dpx
    #   0002.dpx
    #
    #   243_test-01234.dpx
    #   243_test-01235.dpx
    #
    #   scan_00123456.dpx
    #   scan_00123457.dpx
    #
    # Validation rules:
    #   1. Every DPX filename must end in a 4-8 digit frame number.
    #   2. The lowest-numbered valid frame establishes the expected prefix
    #      and frame-number width for the sequence.
    #   3. Every DPX file must use that same prefix and digit width.
    #   4. Frame numbers must be continuous from the lowest frame to the highest.
    #   5. Duplicate frame numbers are rejected.
    #
    # After validation, only the lowest-numbered frame is sent to MediaInfo.
    $finalList = @()
    
    foreach ($dirKey in $dpxGroups.Keys) {
        $dpxList = $dpxGroups[$dirKey]
        $sequenceValid = $true
        $cleanDir = Get-PathParts $dirKey

        # Parse all DPX filenames first. Keep prefix, digit width, and numeric
        # frame value separate so naming errors cannot accidentally fill gaps.
        $parsedFrames = @()
        $invalidNames = @()

        foreach ($dpxPath in $dpxList) {
            $fName = Get-SafeFileName $dpxPath

            # Group 1 = any prefix (including empty)
            # Group 2 = the complete trailing run of frame digits.
            # Capture the complete run first, then enforce 4-8 digits. This
            # prevents a 9+ digit frame number from being misread as a numeric
            # character in the prefix followed by an 8-digit frame number.
            if ($fName -match '^(.*?)(\d+)\.dpx$') {
                $frameText = $matches[2]

                if ($frameText.Length -ge 4 -and $frameText.Length -le 8) {
                    $parsedFrames += [PSCustomObject]@{
                        Path         = $dpxPath
                        FileName     = $fName
                        Prefix       = $matches[1]
                        FrameText    = $frameText
                        FrameWidth   = $frameText.Length
                        FrameNumber  = [long]$frameText
                    }
                }
                else {
                    $invalidNames += $fName
                }
            }
            else {
                $invalidNames += $fName
            }
        }

        # CHECK 1: Every DPX must follow <prefix><4-8-digit-frame>.dpx naming.
        if ($invalidNames.Count -gt 0) {
            $globalHasErrors = $true
            $sequenceValid = $false

            Write-Log "ERROR: Invalid DPX sequence filename(s) in: $($cleanDir.NonPrefixFull)"
            foreach ($badName in ($invalidNames | Select-Object -First 20)) {
                Write-Log "  -> $badName"
            }
            if ($invalidNames.Count -gt 20) {
                Write-Log "  -> ... (more)"
            }
            Write-Log "  -> Expected filename ending: <prefix><4-8-digit-frame>.dpx"
        }

        # CHECK 2: Establish the sequence from the lowest-numbered valid frame.
        # Sort by frame number, then filename to keep the choice deterministic if
        # malformed input contains two differently named files with the same lowest
        # numeric frame. Any such inconsistency is still rejected below.
        $firstFrame = $null
        $expectedPrefix = $null
        $expectedWidth = $null
        $firstFramePath = ""
        $frameNumbers = @()
        $frameMap = @{}
        $duplicateFrames = @()
        $prefixMismatches = @()
        $widthMismatches = @()

        if ($parsedFrames.Count -eq 0) {
            $globalHasErrors = $true
            $sequenceValid = $false
            Write-Log "ERROR: No valid DPX sequence frames found in: $($cleanDir.NonPrefixFull)"
        }
        else {
            $sortedParsedFrames = @($parsedFrames | Sort-Object FrameNumber, FileName)
            $firstFrame = $sortedParsedFrames[0]
            $expectedPrefix = $firstFrame.Prefix
            $expectedWidth = $firstFrame.FrameWidth
            $firstFramePath = $firstFrame.Path

            foreach ($frame in $parsedFrames) {

                # Require an exact prefix match, including case.
                if ($frame.Prefix -cne $expectedPrefix) {
                    $prefixMismatches += $frame
                    continue
                }

                # Require the same number of frame digits throughout the sequence.
                if ($frame.FrameWidth -ne $expectedWidth) {
                    $widthMismatches += $frame
                    continue
                }

                if ($frameMap.ContainsKey($frame.FrameNumber)) {
                    $duplicateFrames += $frame
                    continue
                }

                $frameNumbers += $frame.FrameNumber
                $frameMap[$frame.FrameNumber] = $frame.Path
            }

            # CHECK 3: Prefix consistency.
            if ($prefixMismatches.Count -gt 0) {
                $globalHasErrors = $true
                $sequenceValid = $false

                $displayPrefix = if ([string]::IsNullOrEmpty($expectedPrefix)) { '<none>' } else { $expectedPrefix }
                Write-Log "ERROR: DPX sequence prefix mismatch in: $($cleanDir.NonPrefixFull)"
                Write-Log "  -> Expected prefix: '$displayPrefix'"

                foreach ($badFrame in ($prefixMismatches | Select-Object -First 20)) {
                    $badPrefix = if ([string]::IsNullOrEmpty($badFrame.Prefix)) { '<none>' } else { $badFrame.Prefix }
                    Write-Log "  -> $($badFrame.FileName)  [prefix: '$badPrefix']"
                }
                if ($prefixMismatches.Count -gt 20) {
                    Write-Log "  -> ... (more)"
                }
            }

            # CHECK 4: Frame digit-width consistency.
            if ($widthMismatches.Count -gt 0) {
                $globalHasErrors = $true
                $sequenceValid = $false

                Write-Log "ERROR: DPX frame digit-width mismatch in: $($cleanDir.NonPrefixFull)"
                Write-Log "  -> Expected width: $expectedWidth digit(s)"

                foreach ($badFrame in ($widthMismatches | Select-Object -First 20)) {
                    Write-Log "  -> $($badFrame.FileName)  [width: $($badFrame.FrameWidth)]"
                }
                if ($widthMismatches.Count -gt 20) {
                    Write-Log "  -> ... (more)"
                }
            }

            # CHECK 5: Duplicate frame numbers.
            if ($duplicateFrames.Count -gt 0) {
                $globalHasErrors = $true
                $sequenceValid = $false

                Write-Log "ERROR: Duplicate DPX frame number(s) found in: $($cleanDir.NonPrefixFull)"
                foreach ($dupFrame in ($duplicateFrames | Select-Object -First 20)) {
                    Write-Log "  -> $($dupFrame.FileName)"
                }
                if ($duplicateFrames.Count -gt 20) {
                    Write-Log "  -> ... (more)"
                }
            }

            # CHECK 6: Sequence gaps.
            # Use only frames whose prefix and digit width match the lowest-numbered
            # frame. Therefore a wrong-prefix or wrong-width file cannot hide a gap.
            if ($frameNumbers.Count -gt 0) {
                $frameNumbers = @($frameNumbers | Sort-Object)
                $min = [long]$frameNumbers[0]
                $max = [long]$frameNumbers[$frameNumbers.Count - 1]
                $missingStr = @()

                for ($i = $min; $i -le $max; $i++) {
                    if (-not $frameMap.ContainsKey($i)) {
                        $missingStr += $expectedPrefix + $i.ToString("D$expectedWidth") + ".dpx"
                        if ($missingStr.Count -ge 20) {
                            $missingStr += "... (more)"
                            break
                        }
                    }
                }

                if ($missingStr.Count -gt 0) {
                    $globalHasErrors = $true
                    $sequenceValid = $false

                    Write-Log "ERROR: Missing Frames found in: $($cleanDir.NonPrefixFull)"
                    Write-Log "  -> Frames: $($missingStr -join ', ')"
                    Write-Log "MISSING FRAME DETECTED! Sidecar generation suspended."
                }
            }
        }

        if ($sequenceValid) {
            $finalList += $firstFramePath
        }
        else {
            Write-Log "DPX SEQUENCE VALIDATION FAILED! Sidecar generation suspended for this sequence.`r`n"
        }
    }

    foreach ($f in $filesToProcess) {
        $fDir = Get-SafeDirectoryName $f
        if ($dpxGroups.ContainsKey($fDir)) { continue }
        $finalList += $f
    }

    Write-Log "Processing $($finalList.Count) file(s)...`r`n"
    $prg.Maximum = $finalList.Count; $prg.Value = 0
    
    # 4. PROCESSING
    foreach ($fileLongPath in $finalList) {
        
        $parts = Get-PathParts $fileLongPath

        try {
            $outDirToUse = $parts.LongPathDir
            
            if ($chkSidecarsSub.Checked) {
                $sidecarPathNonPrefix = $parts.NonPrefixDir + "\sidecars"
                $longTargetDir = Get-LongPath $sidecarPathNonPrefix
                $null = [NativeKernelIO]::CreateDirectory($longTargetDir, [IntPtr]::Zero)
                $outDirToUse = $longTargetDir
            }

            $ext = ".txt"; if ($rbJson.Checked) { $ext = ".json" } elseif ($rbXml.Checked) { $ext = ".xml" }
            $outFileName = "$($parts.NonPrefixFile).mediainfo$ext"
            
            $outPath = $outDirToUse + "\" + $outFileName
            
            #$mediaInfoInput = $parts.NonPrefixFull
            $mediaInfoInput = $parts.LongPath

            $argFormat = ""; if ($rbJson.Checked) { $argFormat = "--Output=JSON" } elseif ($rbXml.Checked) { $argFormat = "--Output=XML" }
            
            # Capture output
            if ($argFormat) { 
                $resultLines = & "$mediainfoPath" $argFormat $mediaInfoInput 
            } else { 
                $resultLines = & "$mediainfoPath" $mediaInfoInput 
            }
            
            if ($resultLines -is [array]) {
                $result = $resultLines -join "`r`n"
            } else {
                $result = [string]$resultLines
            }

            Write-NativeText -Path $outPath -Content $result
            if ($rbJson.Checked) {
                $secondaryJsonDirLong = Get-LongPath $SecondaryJsonDir
                $null = [NativeKernelIO]::CreateDirectory($secondaryJsonDirLong, [IntPtr]::Zero)
                $secondaryJsonPath = $secondaryJsonDirLong + "\" + $outFileName
                Write-NativeText -Path $secondaryJsonPath -Content $result
            }


            Write-Log "OK  : $($parts.NonPrefixFile)"
        }
        catch {
            $globalHasErrors = $true
            Write-Log "FAIL: $($parts.NonPrefixFull) -> $($_.Exception.Message)"
        }
        finally {
            $prg.Value++; [System.Windows.Forms.Application]::DoEvents()
        }
    }
    
    if ($globalHasErrors) {
        Write-Log "`r`nDone with Errors."
    } else {
        Write-Log "`r`nDone."
    }
})

[void]$form.ShowDialog()
