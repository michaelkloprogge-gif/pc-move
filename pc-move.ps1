#Requires -Version 5.1
# PC Move: move to a new Windows 10/11 PC without forgetting anything.
#   Start     - "this is my old PC" or "this is my new PC"; finds a move folder on a USB drive by itself
#   Pack up   - on the old PC: programs (through winget), personal folders, Wi-Fi networks, Windows settings,
#               desktop background and browser bookmarks, saved to one folder on a USB drive or external disk
#   Unpack    - on the new PC: installs the programs, copies the files back (never overwriting anything),
#               adds the Wi-Fi networks and applies the settings (with undo)
#   To do     - what can't be moved by a program (sign-ins, programs winget doesn't know, printers), as a checklist
# Every change is logged to %LOCALAPPDATA%\PCMove\changes.log.
# Run PC-Move.exe (this script embedded; rebuild with build-exe.ps1 after editing) or PC-Move.cmd.
# Release a new version: bump $AppVersion, then .\publish-release.ps1 -Notes "...".

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# PC-Move.exe already contains these functions (no compiling at start-up); the plain script compiles them itself.
# Keep in step with the copy in build-exe.ps1.
if (-not ('PcMove.Native' -as [type])) { Add-Type -Namespace PcMove -Name Native -ErrorAction SilentlyContinue -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(int pid);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int attr, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(System.IntPtr h, string app, string idList);
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr h, int msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SystemParametersInfo(int action, int param, string vparam, int flags);
[DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] public static extern bool SystemParametersInfoPtr(int action, int param, System.IntPtr vparam, int flags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr h, int msg, System.IntPtr w, string l, int flags, int timeout, out System.IntPtr result);
'@ }
try { [void][PcMove.Native]::SetProcessDPIAware() } catch { }
[Windows.Forms.Application]::EnableVisualStyles()
$DpiScale = try { [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96 } catch { 1 }
function Px([double]$Pixels) { [int][Math]::Round($Pixels * $DpiScale) }   # for sizes WinForms doesn't scale itself

# Command line (PC-Move.exe /install /uninstall /?). The exe host passes $AppArgs.
$CliArgs = if ($AppArgs) { @($AppArgs) } else { @($args) }
$Cli = @{ Help = $false; Install = $false; Uninstall = $false }
foreach ($a in $CliArgs) {
    switch -Regex ("$a") {
        '^[/-](\?|h|help)$' { $Cli.Help = $true }
        '^[/-]install$' { $Cli.Install = $true }
        '^[/-]uninstall$' { $Cli.Uninstall = $true }
    }
}

$AppVersion = '1.0.0'                  # bump for every release; publish-release.ps1 tags it as v<version>
$UpdateRepo = 'michaelkloprogge-gif/pc-move'         # GitHub repo whose latest release the app updates from

$SelfExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$RunningAsExe = $SelfExe -notmatch '\\(powershell|pwsh)\.exe$'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$DataDir = Join-Path $env:LOCALAPPDATA 'PCMove'
New-Item -ItemType Directory -Force $DataDir | Out-Null
$LogFile = Join-Path $DataDir 'changes.log'
$UndoFile = Join-Path $DataDir 'undo.json'           # the Windows settings PC Move changed, with their old values
$TodoFile = Join-Path $DataDir 'todo.json'           # which to-do items are ticked off
$ErrorLogFile = Join-Path $DataDir 'errors.log'      # problems inside PC Move itself; "Report a problem" includes recent ones
function Write-AppError([string]$Where, $Err) {
    try {
        $msg = if ($Err -is [Management.Automation.ErrorRecord]) {
            $at = if ($Err.InvocationInfo -and $Err.InvocationInfo.ScriptLineNumber) { " [line $($Err.InvocationInfo.ScriptLineNumber): $("$($Err.InvocationInfo.Line)".Trim())]" } else { '' }
            "$($Err.Exception.Message)$at"
        } else { "$Err" }
        Add-Content -Path $ErrorLogFile -Value ('{0:s}  v{1}  {2}: {3}' -f (Get-Date), $AppVersion, $Where, ($msg -replace '\s+', ' ')) -Encoding UTF8
        if ((Get-Item -LiteralPath $ErrorLogFile).Length -gt 256KB) { Set-Content -Path $ErrorLogFile -Value @(Get-Content $ErrorLogFile -Tail 500) -Encoding UTF8 }
    } catch { }
}
function Get-AppErrors([int]$Days = 14) {
    if (-not (Test-Path $ErrorLogFile)) { return }
    $since = (Get-Date).AddDays(-$Days).ToString('s')
    Get-Content $ErrorLogFile -Encoding UTF8 -Tail 300 | Where-Object { $_.Length -ge 19 -and $_.Substring(0, 19) -ge $since }
}
$SettingsFile = Join-Path $DataDir 'settings.json'
$Settings = [ordered]@{ Language = 'auto'; Theme = 'system'; CheckUpdates = $true }
if (Test-Path $SettingsFile) {
    try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { if ($Settings.Contains($_.Name)) { $Settings[$_.Name] = $_.Value } } } catch { }
}
function Save-Settings { $Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 }

# ---------------------------------------------------------------------------
# Language. Code and data stay English; T() translates text on its way to the screen.
# Tables: lang\<code>.tsv, English <TAB> translation, one per line; {0}, {1}... stand for values filled in at run time.
# The exe carries them as resources.
# ---------------------------------------------------------------------------
$Languages = 'nl', 'de', 'fr', 'es', 'it', 'pl'
$Lang = if ($Settings.Language -in @('en') + $Languages) { $Settings.Language } else { $w = (Get-UICulture).TwoLetterISOLanguageName; if ($w -in $Languages) { $w } else { 'en' } }
# Case-sensitive lookups: "Edge" (a browser) and "edge" are different texts.
$script:TExact = New-Object Collections.Hashtable([StringComparer]::Ordinal)
$script:TCache = New-Object Collections.Hashtable([StringComparer]::Ordinal)
$script:TPatterns = @()
$UiCulture = if ($Lang -eq 'en') { [Globalization.CultureInfo]::CurrentCulture } else {
    [Globalization.CultureInfo]::GetCultureInfo(@{ nl = 'nl-NL'; de = 'de-DE'; fr = 'fr-FR'; es = 'es-ES'; it = 'it-IT'; pl = 'pl-PL' }[$Lang]) }
[Threading.Thread]::CurrentThread.CurrentCulture = $UiCulture
function Get-LangTable([string]$Code) {
    try {
        if ($RunningAsExe) {
            $st = [Reflection.Assembly]::GetEntryAssembly().GetManifestResourceStream("$Code.tsv")
            if ($st) { try { return (New-Object IO.StreamReader($st, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $st.Dispose() } }
        }
        $dir = if ($env:PCMOVE_LANGDIR) { $env:PCMOVE_LANGDIR } else { Join-Path (Split-Path -Parent $PSCommandPath) 'lang' }
        $file = Join-Path $dir "$Code.tsv"
        if (Test-Path $file) { return [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) }
    } catch { }
    ''
}
if ($Lang -ne 'en') {
    $pats = foreach ($line in (Get-LangTable $Lang) -split "`r?`n") {
        if (-not $line.Trim()) { continue }
        $en, $tr = $line -split "`t", 2
        if ($en -notmatch '\{\d+\}') { $script:TExact[$en] = $tr; continue }
        $rx = '^' + ([regex]::Escape($en) -replace '\\\{(\d+)}', '(?<p$1>.+?)') + '$'
        @{ Rx = [regex]::new($rx); Tr = $tr; N = ([regex]::Matches($en, '\{\d+\}')).Count; Lit = ($en -replace '\{\d+\}', '').Length }
    }
    $script:TPatterns = @($pats | Sort-Object { $_.Lit } -Descending)   # most specific first; "{0}: {1}" comes last
}
function T([string]$Text, [int]$Depth = 0) {
    if ($Lang -eq 'en' -or -not $Text -or $Depth -gt 3) { return $Text }
    if ($script:TCache.ContainsKey($Text)) { return $script:TCache[$Text] }
    $out = $Text
    if ($Text -match "`n") { $out = (($Text -split "`r?`n") | ForEach-Object { T $_ $Depth }) -join "`r`n" }
    elseif ($Text -match '^(\s*(?:(?:[-!]|\u2022)\s+)?)(.*?)(\s*)$' -and $Matches[2]) {
        $pre = $Matches[1]; $core = $Matches[2]; $post = $Matches[3]
        if ($script:TExact.ContainsKey($core)) { $out = $pre + $script:TExact[$core] + $post }
        else {
            foreach ($p in $script:TPatterns) {
                $m = $p.Rx.Match($core)
                if (-not $m.Success) { continue }
                $vals = @(for ($i = 0; $i -lt $p.N; $i++) { T $m.Groups["p$i"].Value ($Depth + 1) })
                $out = $pre + ($p.Tr -f $vals) + $post
                break
            }
        }
    }
    if ($script:TCache.Count -lt 20000) { $script:TCache[$Text] = $out }
    if ($script:TMiss -and $out -ceq $Text -and $Depth -eq 0) { [void]$script:TMiss.Add($Text) }   # tests: texts with no translation
    $out
}
$script:TMiss = if ($env:PCMOVE_TRACKT) { New-Object Collections.Generic.HashSet[string] } else { $null }
# Translate a window's controls now, and again whenever their text changes later.
function Enable-Translation($Control) {
    if ($Lang -eq 'en') { return }
    $translatable = $Control -is [Windows.Forms.Label] -or $Control -is [Windows.Forms.ButtonBase] -or
                    ($Control -is [Windows.Forms.TextBox] -and $Control.ReadOnly)
    if ($translatable) {
        $Control.Text = T $Control.Text
        $Control.Add_TextChanged({ if (-not $script:InT) { $script:InT = $true; $t = T $this.Text; if ($t -ne $this.Text) { $this.Text = $t }; $script:InT = $false } })
    }
    if ($Control -is [Windows.Forms.ListView]) { foreach ($c in $Control.Columns) { $c.Text = T $c.Text } }
    foreach ($child in $Control.Controls) { Enable-Translation $child }
}
# Installed copy: per user, no administrator needed.
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PC Move'
$InstalledExe = Join-Path $InstallDir 'PC-Move.exe'
$IsInstalled = $RunningAsExe -and ($SelfExe -eq $InstalledExe)
$FromWinget = $RunningAsExe -and $SelfExe -match '\\Microsoft\\WinGet\\(Packages|Links)\\'
# From the Microsoft Store (an MSIX package): the Store installs and updates it, and starts it through its alias.
$FromStore = $RunningAsExe -and (Test-Path -LiteralPath (Join-Path (Split-Path $SelfExe) 'AppxManifest.xml'))
$StartExe = if ($FromStore) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pc-move.exe' } else { $SelfExe }

function Write-Log([string]$Msg) {
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg) -Encoding UTF8
}
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f ($Bytes / 1KB) }
}
function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    [Windows.Forms.MessageBox]::Show((T $Text), 'PC Move', $Buttons, $Icon)
}
function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}
function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($null -eq $Value) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type }
}

# ---------------------------------------------------------------------------
# What can be moved
# ---------------------------------------------------------------------------
# Personal folders, as Windows knows them on each PC (they may live in OneDrive or on another drive).
function Get-PersonalFolders {
    $dl = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' '{374DE290-123F-4565-9164-39C4925E467B}'
    $dl = if ($dl) { [Environment]::ExpandEnvironmentVariables($dl) } else { Join-Path $env:USERPROFILE 'Downloads' }
    @(
        @{ Key = 'Desktop';   Name = 'Desktop';   Path = [Environment]::GetFolderPath('Desktop') }
        @{ Key = 'Documents'; Name = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') }
        @{ Key = 'Pictures';  Name = 'Pictures';  Path = [Environment]::GetFolderPath('MyPictures') }
        @{ Key = 'Music';     Name = 'Music';     Path = [Environment]::GetFolderPath('MyMusic') }
        @{ Key = 'Videos';    Name = 'Videos';    Path = [Environment]::GetFolderPath('MyVideos') }
        @{ Key = 'Downloads'; Name = 'Downloads'; Path = $dl }
        @{ Key = 'Favorites'; Name = 'Favorites'; Path = [Environment]::GetFolderPath('Favorites') }
    ) | Where-Object { $_.Path } | ForEach-Object {
        $od = foreach ($o in $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) { if ($o -and $_.Path.StartsWith($o.TrimEnd('\') + '\', 'OrdinalIgnoreCase')) { $o } }
        $_.OneDrive = [bool]$od
        [pscustomobject]$_
    }
}
# Windows settings that are safe to copy: per user, plain values, no administrator needed.
# Values maps a stored value to words; settings without a match show the raw value.
$Win11 = [int](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild') -ge 22000
$SettingsCatalog = @(
    @{ Key = 'AppsTheme';    Name = 'App colours';               P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'AppsUseLightTheme'; Values = @{ '0' = 'dark'; '1' = 'light' } }
    @{ Key = 'SystemTheme';  Name = 'Windows colours';           P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; N = 'SystemUsesLightTheme'; Values = @{ '0' = 'dark'; '1' = 'light' } }
    @{ Key = 'TaskbarAlign'; Name = 'Taskbar icons';             P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarAl'; Values = @{ '0' = 'on the left'; '1' = 'in the centre' }; Win11 = $true }
    @{ Key = 'SearchBox';    Name = 'Search on the taskbar';     P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; N = 'SearchboxTaskbarMode'; Values = @{ '0' = 'hidden'; '1' = 'icon'; '2' = 'search box'; '3' = 'icon and label' } }
    @{ Key = 'FileExt';      Name = 'File name extensions';      P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'HideFileExt'; Values = @{ '0' = 'shown'; '1' = 'hidden' } }
    @{ Key = 'HiddenFiles';  Name = 'Hidden files';              P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Hidden'; Values = @{ '1' = 'shown'; '2' = 'hidden' } }
    @{ Key = 'ExplorerOpen'; Name = 'File Explorer opens on';    P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'LaunchTo'; Values = @{ '1' = 'This PC'; '2' = 'Home'; '3' = 'Downloads' } }
    @{ Key = 'MouseSpeed';   Name = 'Mouse pointer speed';       P = 'HKCU:\Control Panel\Mouse'; N = 'MouseSensitivity'; T = 'String'; Values = @{} }
    @{ Key = 'ClickLock';    Name = 'Double-click speed';        P = 'HKCU:\Control Panel\Mouse'; N = 'DoubleClickSpeed'; T = 'String'; Values = @{} }
) | Where-Object { -not $_.Win11 -or $Win11 }
function Get-SettingText($S, $Value) {
    if ($null -eq $Value) { return 'Windows default' }
    $w = $S.Values["$Value"]
    if ($w) { $w } else { "$Value" }
}
# Where Windows keeps the desktop background. The original file may be gone; Windows keeps its own copy too.
function Get-WallpaperFile {
    $p = Get-RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper'
    if ($p -and (Test-Path -LiteralPath $p) -and $p -notmatch '\\Windows\\Web\\') { return $p }   # Windows' own pictures are on every PC
    $t = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper'
    if ($p -and $p -notmatch '\\Windows\\Web\\' -and (Test-Path -LiteralPath $t)) { return $t }
    $null
}
# Programs every PC already has, or that come with other programs: never worth installing by hand.
$FrameworkRx = '^Microsoft\.(VCRedist|VCLibs|UI\.Xaml|DotNet\.(Runtime|DesktopRuntime|AspNetCore|HostingBundle)|WindowsAppRuntime|DirectX|EdgeWebView2Runtime|Edge|AppInstaller|OneDrive|WindowsTerminal|DesktopAppInstaller|NET\.Native|Services\.Store|StorePurchaseApp|WindowsStore|SecHealthUI|GamingServices)\b|^9WZDNCRFJ3PS$|^9NBLGGH4NNS1$'
# Programs without a winget package that are not worth a to-do line either (drivers, runtimes, parts of Windows).
$NotProgramRx = '(?i)redistributable|runtime|\bdriver|update for|hotfix|\bSDK\b|\.NET|WebView2|Visual C\+\+|Windows Software Development|DirectX|Microsoft Edge|OneDrive|Machine-Wide|Office 16 Click-to-Run|Microsoft Update Health|Windows PC Health Check|GameInput|Realtek|Intel\(R\)|Intel\u00AE|Intel |NVIDIA|AMD |Radeon|Synaptics|ELAN|Dolby|Waves|Conexant|Bonjour|vcpp|vs_|Microsoft Visual Studio Installer|Telemetry|Auto Updater|Windows Driver Package|Battery|Thunderbolt|Bluetooth|Chipset|Firmware|BIOS|ODBC|OLE DB|Native Client|Genuine Service|Help Viewer|Compatibility Fix|Add-in|Plug-?in\b|Updater\b|\(remove only\)|Tools for Applications|Python Launcher|App Installer|Windows Terminal|Maintenance Service|CLR Types|Management Objects|LocalDB|Data-Tier|Integration Services'
# Tools from the PC's maker: only useful on a PC of the same brand.
$MakerRx = '(?i)^(Dell|HP|Hewlett|Lenovo|ASUS|Acer|MSI|Samsung|Microsoft Surface)\b|SupportAssist|MyASUS|Armoury Crate|Vantage'

# ---------------------------------------------------------------------------
# Background work: long jobs run in a separate runspace so the window stays responsive.
# A timer polls them and calls the Done block.
# ---------------------------------------------------------------------------
$Helpers = @'
function Get-FilesSafe([string]$Root) {
    if (-not [IO.Directory]::Exists($Root)) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.DirectoryInfo]$Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try {
            foreach ($e in $dir.EnumerateFileSystemInfos()) {
                if ($e -is [IO.DirectoryInfo]) {
                    if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($e) }
                } else { $e }
            }
        } catch { }
    }
}
# Run a console program hidden and capture its output as UTF-8 (winget prints Unicode names).
function Invoke-Native([string]$Exe, [string]$Arguments, [int]$TimeoutSec = 600) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe, $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.WaitForExit(500)) {   # check twice a second whether the user pressed Cancel
        if (($Job -and $Job.Cancel) -or (Get-Date) -gt $deadline) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Out = ''; Code = -1; TimedOut = -not ($Job -and $Job.Cancel); Cancelled = [bool]($Job -and $Job.Cancel) }
        }
    }
    [pscustomobject]@{ Out = $out.Result + $err.Result; Code = $p.ExitCode; TimedOut = $false; Cancelled = $false }
}
# The last line winget printed that says something (not a progress bar or spinner).
function Get-LastLine([string]$Out) {
    $Out -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1].Trim() } |
        Where-Object { $_ -and $_ -notmatch '^[\-\\|/\s]+$' -and $_ -notmatch '\d+(\.\d+)? ?[KMG]B ?/ ?\d' -and $_ -notmatch '^[\u2580-\u259F\s]+' } | Select-Object -Last 1
}
# Copies a folder with robocopy, counting the bytes of each copied file for the progress bar.
# Never follows junctions; -SkipExisting leaves every file that is already there alone.
function Invoke-Copy([string]$From, [string]$To, [string]$Label, [double]$DoneBefore, [double]$Total, [switch]$SkipExisting) {
    $a = "`"$($From.TrimEnd('\'))`" `"$($To.TrimEnd('\'))`" /E /XJ /R:1 /W:1 /NP /NDL /NJH /NJS /BYTES /FP /COPY:DAT /DCOPY:T /XF desktop.ini thumbs.db"
    if ($SkipExisting) { $a += ' /XC /XN /XO' }
    $psi = New-Object Diagnostics.ProcessStartInfo "$env:windir\System32\robocopy.exe", $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $bytes = 0.0; $files = 0; $tick = [Diagnostics.Stopwatch]::StartNew()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($Job -and $Job.Cancel) { try { $p.Kill() } catch { }; break }
        if ($line -match '\t\s*(\d+)\t') { $bytes += [double]$Matches[1]; $files++ }
        if ($tick.ElapsedMilliseconds -gt 300) { $tick.Restart(); Set-JobProgress $Label ([int](($DoneBefore + $bytes) / 1MB)) ([int][Math]::Max(1, $Total / 1MB)) }
    }
    $p.WaitForExit()
    # robocopy: 0-7 means it worked (1 = files copied, 2/3 = extra files), 8 and up means some files failed.
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Ok = ($p.ExitCode -lt 8); Code = $p.ExitCode; Cancelled = [bool]($Job -and $Job.Cancel) }
}
function Set-JobProgress([string]$Text, [int]$Value = -1, [int]$Max = 0) {
    if ($Job) { $Job.Text = $Text; $Job.Value = $Value; $Job.Max = $Max }
}
function Test-Cancelled { [bool]($Job -and $Job.Cancel) }
# A winget table ("winget list") as rows. Header names are translated on non-English Windows, so
# columns are found by position: where each header word starts.
function ConvertFrom-WingetTable([string]$Out) {
    $lines = @($Out -split "`n" | ForEach-Object { ($_.TrimEnd("`r") -split "`r")[-1] })
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{20,}\s*$') { continue }
        $hdr = $lines[$i - 1]
        $starts = @(0) + @([regex]::Matches($hdr, '(?<=\s)\S') | ForEach-Object Index)
        if ($starts.Count -lt 3) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if (-not $l.Trim()) { break }
            if ($l.Length -le $starts[2]) { continue }
            $cut = { param($a, $b) if ($a -ge $l.Length) { '' } elseif ($b -and $b -lt $l.Length) { $l.Substring($a, $b - $a).Trim() } else { $l.Substring($a).Trim() } }
            $cols = @(for ($k = 0; $k -lt $starts.Count; $k++) { & $cut $starts[$k] $(if ($k + 1 -lt $starts.Count) { $starts[$k + 1] } else { $null }) })
            # Name, Id, Version, [Available], Source: the source is the last column, and only winget/msstore count.
            [pscustomobject]@{ Name = $cols[0]; Id = $cols[1]; Source = $(if ($cols[-1] -in 'winget', 'msstore') { $cols[-1] } else { '' }) }
        }
    }
}
# The installed programs winget can install again, by id (winget export never cuts ids off, unlike winget list).
function Get-WingetExport([string]$Wg) {
    $f = Join-Path $env:TEMP "pcmove-export-$PID.json"
    $r = Invoke-Native $Wg "export -o `"$f`" --accept-source-agreements --disable-interactivity" 300
    $ids = @()
    try {
        if (Test-Path $f) {
            $x = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $ids = @(foreach ($s in $x.Sources) { foreach ($p in $s.Packages) { [pscustomobject]@{ Id = $p.PackageIdentifier; Source = $(if ($s.SourceDetails.Name -eq 'msstore') { 'msstore' } else { 'winget' }) } } })
        }
    } catch { }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Ids = $ids; TimedOut = $r.TimedOut; Cancelled = $r.Cancelled }
}
# A Chromium "Bookmarks" file as the bookmarks.html file every browser can import.
function ConvertTo-BookmarkHtml($Json) {
    $sb = New-Object Text.StringBuilder
    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $script:BmCount = 0
    $add = $null
    $add = {
        param($n, [string]$Pad)
        if ($n.type -eq 'url') { [void]$sb.AppendLine("$Pad<DT><A HREF=`"$(& $enc $n.url)`">$(& $enc $n.name)</A>"); $script:BmCount++ }
        elseif ($n.type -eq 'folder') {
            [void]$sb.AppendLine("$Pad<DT><H3>$(& $enc $n.name)</H3>"); [void]$sb.AppendLine("$Pad<DL><p>")
            foreach ($c in @($n.children)) { & $add $c "$Pad    " }
            [void]$sb.AppendLine("$Pad</DL><p>")
        }
    }
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine('<TITLE>Bookmarks</TITLE>'); [void]$sb.AppendLine('<H1>Bookmarks</H1>'); [void]$sb.AppendLine('<DL><p>')
    foreach ($root in 'bookmark_bar', 'other', 'synced') {
        $r = $Json.roots.$root
        if (-not $r -or -not @($r.children).Count) { continue }
        $attr = if ($root -eq 'bookmark_bar') { ' PERSONAL_TOOLBAR_FOLDER="true"' } else { '' }
        [void]$sb.AppendLine("    <DT><H3$attr>$(& $enc $r.name)</H3>"); [void]$sb.AppendLine('    <DL><p>')
        foreach ($c in @($r.children)) { & $add $c '        ' }
        [void]$sb.AppendLine('    </DL><p>')
    }
    [void]$sb.AppendLine('</DL><p>')
    [pscustomobject]@{ Html = $sb.ToString(); Count = $script:BmCount }
}
'@

$script:Jobs = New-Object System.Collections.ArrayList
# -Label shows the job in the activity bar at the bottom of the window; -Cancellable adds a Cancel button.
# The Done block gets the results, and the job's state as a second argument ($State.Cancel says if it was stopped).
function Start-Bg([scriptblock]$Work, $Arg, [scriptblock]$Done, [string]$Label, [switch]$Cancellable) {
    $code = "param(`$BgArg)`n$Helpers`n& {`n$Work`n} `$BgArg"
    $state = [hashtable]::Synchronized(@{ Text = ''; Value = -1; Max = 0; Cancel = $false })
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('Job', $state)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($code).AddArgument($Arg)
    [void]$script:Jobs.Add(@{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Done = $Done; Label = $Label; State = $state; Cancellable = [bool]$Cancellable })
    if ($activity) { Update-ActivityBar }
}
$JobTimer = New-Object Windows.Forms.Timer
$JobTimer.Interval = 250
$JobTimer.Add_Tick({
    foreach ($j in @($script:Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        [void]$script:Jobs.Remove($j)
        $what = if ($j.Label) { $j.Label } else { 'a background check' }
        try { $result = @($j.PS.EndInvoke($j.Handle)) }
        catch {
            $result = @(); Write-AppError "$what (background)" $_
            if ((Show-Msg "Something went wrong:`n$($_.Exception.Message)`n`nReport this problem? (Opens GitHub with the details filled in - you see everything before you send it.)" 'YesNo' 'Warning') -eq 'Yes') { Open-ProblemReport 'bug' }
        }
        foreach ($e in @($j.PS.Streams.Error)) { Write-AppError "$what (background)" $e }
        $j.PS.Dispose(); $j.RS.Dispose()
        try { & $j.Done $result $j.State } catch { Write-AppError "$what (showing the result)" $_ }
    }
    if ($activity) { Update-ActivityBar }
})
$JobTimer.Start()

# ---------------------------------------------------------------------------
# Window, theme and layout helpers (the same look as PC Tune-Up)
# ---------------------------------------------------------------------------
function Rgb([int]$R, [int]$G, [int]$B) { [Drawing.Color]::FromArgb($R, $G, $B) }
$WindowsDark = (Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme') -eq 0
$Dark = switch ($Settings.Theme) { 'dark' { $true } 'light' { $false } default { $WindowsDark } }
$Theme = if (-not $Dark) {
    @{  Bg = (Rgb 255 255 255); Input = (Rgb 255 255 255); Side = (Rgb 243 244 246); Hover = (Rgb 229 231 235)
        Text = (Rgb 32 32 32); Dim = (Rgb 105 105 110); Border = (Rgb 206 209 214); Soft = (Rgb 246 247 249)
        Accent = (Rgb 0 120 110); AccentDark = (Rgb 0 98 90); AccentSoft = (Rgb 220 240 237); AccentText = (Rgb 0 110 100)
        WarnBg = (Rgb 255 245 219); WarnText = (Rgb 128 68 0)
        Bad = (Rgb 176 32 32); Warn = (Rgb 196 98 0); Good = (Rgb 20 120 50); Muted = (Rgb 130 130 135) }
} else {
    @{  Bg = (Rgb 32 32 34); Input = (Rgb 45 45 48); Side = (Rgb 43 43 46); Hover = (Rgb 58 58 62)
        Text = (Rgb 236 236 236); Dim = (Rgb 165 165 170); Border = (Rgb 82 82 88); Soft = (Rgb 44 44 48)
        Accent = (Rgb 0 128 116); AccentDark = (Rgb 0 106 96); AccentSoft = (Rgb 30 66 62); AccentText = (Rgb 100 215 200)
        WarnBg = (Rgb 64 50 22); WarnText = (Rgb 255 208 130)
        Bad = (Rgb 255 120 110); Warn = (Rgb 255 178 80); Good = (Rgb 110 205 135); Muted = (Rgb 140 140 146) }
}
function Set-DarkChrome($Control, [string]$ThemeName = 'DarkMode_Explorer') {
    if (-not $Dark) { return }
    try { [void][PcMove.Native]::SetWindowTheme($Control.Handle, $ThemeName, $null) } catch { }
}
$Font = New-Object Drawing.Font('Segoe UI', 9.75)
$FontBold = New-Object Drawing.Font('Segoe UI Semibold', 9.75)
$FontSmall = New-Object Drawing.Font('Segoe UI Semibold', 8.25)
$FontTitle = New-Object Drawing.Font('Segoe UI Semibold', 16)
$FontBig = New-Object Drawing.Font('Segoe UI Semibold', 13)
$form = New-Object Windows.Forms.Form
$form.Text = "PC Move $AppVersion" + $(if ($IsAdmin) { '  (Administrator)' } else { '' })
$form.AutoScaleMode = 'None'
$form.ClientSize = New-Object Drawing.Size(1040, 680)
$form.StartPosition = 'CenterScreen'
$form.Font = $Font; $form.BackColor = $Theme.Bg; $form.ForeColor = $Theme.Text
$form.Add_HandleCreated({
    if ($Dark) { $on = 1; try { [void][PcMove.Native]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4) } catch { } }   # 20 = dark title bar
})
if ($RunningAsExe) { try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($SelfExe) } catch { } }

$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'; $content.BackColor = $Theme.Bg
$sidebar = New-Object Windows.Forms.Panel
$sidebar.Dock = 'Left'; $sidebar.Width = 196; $sidebar.BackColor = $Theme.Side
$form.Controls.Add($content); $form.Controls.Add($sidebar)
$script:Pages = New-Object System.Collections.ArrayList

function New-Page([string]$Title, [string]$IntroText) {
    $page = New-Object Windows.Forms.Panel
    $page.Name = $Title; $page.Text = $Title; $page.Dock = 'Fill'; $page.Visible = $false
    $page.Padding = New-Object Windows.Forms.Padding(26, 16, 26, 12); $page.BackColor = $Theme.Bg
    $content.Controls.Add($page)
    [void]$script:Pages.Add($page)
    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = 80
    $t = New-Object Windows.Forms.Label
    $t.Text = $Title; $t.Font = $FontTitle; $t.Dock = 'Top'; $t.Height = 36
    $d = New-Object Windows.Forms.Label
    $d.Text = $IntroText; $d.ForeColor = $Theme.Dim; $d.Dock = 'Fill'
    $head.Controls.Add($d); $head.Controls.Add($t)
    $page.Tag = $head
    $page
}
# Docking is laid out last-added-first, so: Fill control, then bottom, then top controls from the lowest one upward.
function Set-PageLayout($Page, $Fill, [object[]]$Tops, $Bottom) {
    $n = 0; foreach ($t in $Tops) { $t.TabIndex = $n++ }; $Fill.TabIndex = $n++; if ($Bottom) { $Bottom.TabIndex = $n }
    if ($Fill -is [Windows.Forms.ListView]) { $Fill.AccessibleName = "$($Page.Name)"; $Fill.AccessibleDescription = $Page.Tag.Controls[0].Text }
    $Page.Controls.Add($Fill)
    if ($Bottom) { $Page.Controls.Add($Bottom) }
    [array]::Reverse($Tops)
    foreach ($t in $Tops) { $Page.Controls.Add($t) }
    $Page.Controls.Add($Page.Tag)
}
function New-ButtonBar([object[]]$Buttons) {
    $bar = New-Object Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.AutoSize = $true; $bar.AutoSizeMode = 'GrowAndShrink'; $bar.WrapContents = $true
    $bar.Padding = New-Object Windows.Forms.Padding(0, 2, 0, 6)
    foreach ($b in $Buttons) { $bar.Controls.Add($b) }
    $bar
}
function New-Button([string]$Text) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true; $b.MinimumSize = New-Object Drawing.Size(0, 34)
    $b.Padding = New-Object Windows.Forms.Padding(10, 0, 10, 0); $b.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 6)
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.BackColor = $Theme.Bg; $b.ForeColor = $Theme.Text; $b.FlatAppearance.BorderColor = $Theme.Border; $b.FlatAppearance.MouseOverBackColor = $Theme.Soft
    $b.FlatAppearance.BorderSize = 0
    $b.Add_Paint({ param($sender, $e) Draw-Button $sender $e.Graphics })
    $b.Add_MouseEnter({ $script:HotButton = $this; $this.Invalidate() })
    $b.Add_MouseLeave({ if ($script:HotButton -eq $this) { $script:HotButton = $null }; $this.Invalidate() })
    $b
}
function New-RoundRect([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [single][Math]::Max([double]1, [Math]::Min([double]($R * 2), [Math]::Min([double]$W, [double]$H)))
    $p.AddArc($X, $Y, $d, $d, 180, 90); $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90); $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90); $p.CloseFigure()
    $p
}
function Draw-Button($B, $G) {
    $G.SmoothingMode = 'AntiAlias'
    $G.Clear($(if ($B.Parent) { $B.Parent.BackColor } else { $Theme.Bg }))
    $primary = $B.BackColor.ToArgb() -eq $Theme.Accent.ToArgb()
    $fill = if (-not $B.Enabled) { if ($primary) { $Theme.Soft } else { $B.BackColor } } elseif ($script:HotButton -eq $B) { $B.FlatAppearance.MouseOverBackColor } else { $B.BackColor }
    $path = New-RoundRect 0.5 0.5 ($B.Width - 1.5) ($B.Height - 1.5) (Px 6)
    $br = New-Object Drawing.SolidBrush($fill); $G.FillPath($br, $path); $br.Dispose()
    if (-not $primary -or -not $B.Enabled) { $pen = New-Object Drawing.Pen($(if ($script:HotButton -eq $B -and $B.Enabled) { $Theme.Dim } else { $Theme.Border })); $G.DrawPath($pen, $path); $pen.Dispose() }
    $path.Dispose()
    $flags = [Windows.Forms.TextFormatFlags]'VerticalCenter, EndEllipsis'
    if ($B.TextAlign -in 'MiddleLeft', 'TopLeft', 'BottomLeft') { $flags = $flags -bor [Windows.Forms.TextFormatFlags]::Left } else { $flags = $flags -bor [Windows.Forms.TextFormatFlags]::HorizontalCenter }
    if ($B.Text -match "`n") { $flags = $flags -bor [Windows.Forms.TextFormatFlags]::WordBreak }
    if (-not $B.UseMnemonic) { $flags = $flags -bor [Windows.Forms.TextFormatFlags]::NoPrefix }
    $r = if ($flags -band [Windows.Forms.TextFormatFlags]::HorizontalCenter) { New-Object Drawing.Rectangle(2, 0, ($B.Width - 4), $B.Height) }
         else { New-Object Drawing.Rectangle($B.Padding.Left, 0, ($B.Width - $B.Padding.Horizontal), $B.Height) }
    [Windows.Forms.TextRenderer]::DrawText($G, $B.Text, $B.Font, $r, $(if ($B.Enabled) { $B.ForeColor } else { $Theme.Muted }), $flags)
    if ($B.Focused -and $B.ShowFocusCues) {
        $fp = New-RoundRect 2.5 2.5 ($B.Width - 5.5) ($B.Height - 5.5) (Px 4)
        $pen = New-Object Drawing.Pen($(if ($primary) { [Drawing.Color]::White } else { $Theme.Accent }), 1); $pen.DashStyle = 'Dot'; $G.DrawPath($pen, $fp); $pen.Dispose(); $fp.Dispose()
    }
}
function Set-Primary($Button) {
    $Button.Font = $FontBold; $Button.FlatAppearance.MouseOverBackColor = $Theme.AccentDark
    $Button.Add_EnabledChanged({ Update-PrimaryLook $this })
    Update-PrimaryLook $Button
}
function Update-PrimaryLook($Button) {
    if ($Button.Enabled) { $Button.BackColor = $Theme.Accent; $Button.ForeColor = [Drawing.Color]::White; $Button.FlatAppearance.BorderSize = 0 }
    else { $Button.BackColor = $Theme.Soft; $Button.ForeColor = $Theme.Dim; $Button.FlatAppearance.BorderSize = 1 }
}
$script:HotRows = @{}
function Set-HotRow($Lv, $Item) {
    $k = $Lv.GetHashCode(); $old = $script:HotRows[$k]
    if ($old -eq $Item) { return }
    foreach ($pair in @(@($old, $Theme.Bg), @($Item, $Theme.Hover))) {
        $it = $pair[0]; if (-not $it -or -not $it.ListView) { continue }
        $it.BackColor = $pair[1]; if (-not $it.UseItemStyleForSubItems) { foreach ($si in $it.SubItems) { $si.BackColor = $pair[1] } }
    }
    $script:HotRows[$k] = $Item
}
# The status column shows a coloured dot and word; the rest of the row stays easy to read.
function Set-RowStatus($Item, [int]$Col, [string]$Text, $Color) {
    $Item.UseItemStyleForSubItems = $false
    foreach ($si in $Item.SubItems) { $si.ForeColor = $Theme.Text }
    $si = $Item.SubItems[$Col]
    if ($Color.ToArgb() -eq $Theme.Muted.ToArgb()) { $si.Text = T $Text; foreach ($s in $Item.SubItems) { $s.ForeColor = $Theme.Muted }; return }
    $si.Text = "$([char]0x25CF)  $(T $Text)"; $si.ForeColor = $Color
}
function New-ListView([bool]$Checks, [object[]]$Columns) {
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.CheckBoxes = $Checks; $lv.Dock = 'Fill'; $lv.ShowItemToolTips = $true
    $lv.BorderStyle = 'None'; $lv.HeaderStyle = 'Nonclickable'; $lv.BackColor = $Theme.Bg; $lv.ForeColor = $Theme.Text
    $rows = New-Object Windows.Forms.ImageList; $rows.ImageSize = New-Object Drawing.Size(1, (Px 28))   # taller rows
    $lv.Add_MouseMove({ Set-HotRow $this ($this.GetItemAt($_.X, $_.Y)) })
    $lv.Add_MouseLeave({ Set-HotRow $this $null })
    $lv.SmallImageList = $rows
    for ($i = 0; $i -lt $Columns.Count; $i += 2) { [void]$lv.Columns.Add($Columns[$i], (Px $Columns[$i + 1])) }
    if ($Dark) {   # the native header ignores colours, so draw it; rows still draw themselves
        $lv.OwnerDraw = $true
        $lv.Add_DrawColumnHeader({
            param($sender, $e)
            $fillR = $e.Bounds
            if ($e.ColumnIndex -eq $sender.Columns.Count - 1) { $fillR = New-Object Drawing.Rectangle($e.Bounds.X, $e.Bounds.Y, [Math]::Max($e.Bounds.Width, $sender.Width - $e.Bounds.X), $e.Bounds.Height) }
            $brush = New-Object Drawing.SolidBrush($Theme.Side); $e.Graphics.FillRectangle($brush, $fillR); $brush.Dispose()
            $r = $e.Bounds; $r.X += (Px 5); $r.Width -= (Px 5)
            [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $sender.Font, $r, $Theme.Dim, 'VerticalCenter, Left, EndEllipsis')
        })
        $lv.Add_DrawItem({ param($sender, $e) $e.DrawDefault = $true })
        $lv.Add_DrawSubItem({ param($sender, $e) $e.DrawDefault = $true })
    }
    $lv.Add_HandleCreated({
        Set-DarkChrome $this
        $header = [PcMove.Native]::SendMessage($this.Handle, 0x101F, [IntPtr]::Zero, [IntPtr]::Zero)   # LVM_GETHEADER
        if ($Dark -and $header -ne [IntPtr]::Zero) { try { [void][PcMove.Native]::SetWindowTheme($header, 'DarkMode_ItemsView', $null) } catch { } }
    })
    $lv.Tag = @($lv.Columns | ForEach-Object Width)   # designed widths
    $lv.Add_Resize({ Resize-LastColumn $this })
    $lv
}
# Let the last column take the remaining width, so lists never scroll sideways.
function Resize-LastColumn($Lv) {
    $n = $Lv.Columns.Count
    if ($n -lt 2) { return }
    $avail = $Lv.ClientSize.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
    $design = @($Lv.Tag)
    $fixed = 0; for ($i = 0; $i -lt $n - 1; $i++) { $fixed += $design[$i] }
    $scale = [Math]::Min(1.0, [Math]::Max(0.3, ($avail - 160) / [Math]::Max(1, $fixed)))
    $used = 0
    for ($i = 0; $i -lt $n - 1; $i++) { $w = [int]($design[$i] * $scale); $Lv.Columns[$i].Width = $w; $used += $w }
    $Lv.Columns[$n - 1].Width = [Math]::Max(120, $avail - $used)
}
function New-Status {
    $l = New-Object Windows.Forms.Label
    $l.Dock = 'Bottom'; $l.Height = 32; $l.TextAlign = 'BottomLeft'; $l.ForeColor = $Theme.Dim; $l.AutoEllipsis = $true
    $l
}
# A coloured note above a list (where things are saved, what was found); grows to fit its text.
function New-Note {
    $l = New-Object Windows.Forms.Label
    $l.Dock = 'Top'; $l.Height = 0; $l.BackColor = $Theme.AccentSoft; $l.ForeColor = $Theme.Text
    $l.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)
    $l.Add_TextChanged({ Resize-Note $this }); $l.Add_Resize({ Resize-Note $this })
    $l
}
function Resize-Note($L) {
    if (-not $L.Text) { if ($L.Height) { $L.Height = 0 }; return }
    $sz = [Windows.Forms.TextRenderer]::MeasureText($L.Text, $L.Font, (New-Object Drawing.Size(($L.Width - $L.Padding.Horizontal), 0)), 'WordBreak')
    $h = $sz.Height + $L.Padding.Vertical + 2
    if ($L.Height -ne $h) { $L.Height = $h }
}
function Add-Row($Lv, [object[]]$Cells, $Tag = $null, [bool]$Checked = $false) {
    $it = New-Object Windows.Forms.ListViewItem((T ([string]$Cells[0])))
    foreach ($c in $Cells[1..($Cells.Count - 1)]) { [void]$it.SubItems.Add((T ([string]$c))) }
    $it.Tag = $Tag; $it.Checked = $Checked
    [void]$Lv.Items.Add($it)
    $it
}
# The kinds of things that move, in the order they are listed.
$KindOrder = @{ App = 1; Folder = 2; WiFi = 3; Setting = 4; Wallpaper = 5; Bookmarks = 6 }
$KindName = @{ App = 'Program'; Folder = 'Folder'; WiFi = 'Wi-Fi'; Setting = 'Setting'; Wallpaper = 'Setting'; Bookmarks = 'Bookmarks' }

# ===========================================================================
# 1. Start
# ===========================================================================
$pgStart = New-Page 'Start' 'PC Move takes your programs, files, Wi-Fi networks and settings from your old PC to your new one. Run it on the old PC first, then on the new one.'
$startFlow = New-Object Windows.Forms.FlowLayoutPanel
$startFlow.Dock = 'Fill'; $startFlow.FlowDirection = 'TopDown'; $startFlow.WrapContents = $false; $startFlow.AutoScroll = $true
$startTiles = New-Object Windows.Forms.FlowLayoutPanel
$startTiles.AutoSize = $true; $startTiles.WrapContents = $true; $startTiles.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 10)
# A big choice button: a title in a large font, an explanation under it. The first line of Text is the title.
function New-Tile([string]$Text, [bool]$Primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object Drawing.Size(330, 104); $b.Margin = New-Object Windows.Forms.Padding(0, 0, 14, 8)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.UseVisualStyleBackColor = $false; $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Tag = $Primary
    $b.Add_Paint({ param($s, $e) Draw-Tile $s $e.Graphics })
    $b.Add_MouseEnter({ $script:HotButton = $this; $this.Invalidate() })
    $b.Add_MouseLeave({ if ($script:HotButton -eq $this) { $script:HotButton = $null }; $this.Invalidate() })
    $b
}
function Draw-Tile($B, $G) {
    $G.SmoothingMode = 'AntiAlias'; $G.Clear($B.Parent.BackColor)
    $hot = $script:HotButton -eq $B
    $fill = if ($B.Tag) { if ($hot) { $Theme.AccentDark } else { $Theme.Accent } } elseif ($hot) { $Theme.Soft } else { $Theme.Bg }
    $path = New-RoundRect 0.5 0.5 ($B.Width - 1.5) ($B.Height - 1.5) (Px 8)
    $br = New-Object Drawing.SolidBrush($fill); $G.FillPath($br, $path); $br.Dispose()
    if (-not $B.Tag) { $pen = New-Object Drawing.Pen($(if ($hot) { $Theme.Dim } else { $Theme.Border })); $G.DrawPath($pen, $path); $pen.Dispose() }
    $path.Dispose()
    $title, $sub = "$($B.Text)" -split "`r?`n", 2
    $fg = if ($B.Tag) { [Drawing.Color]::White } else { $Theme.Text }
    $pad = Px 20
    $th = [Windows.Forms.TextRenderer]::MeasureText($title, $FontBig).Height
    $sh = [Windows.Forms.TextRenderer]::MeasureText($sub, $Font, (New-Object Drawing.Size(($B.Width - 2 * $pad), 0)), 'WordBreak').Height
    $y = [int](($B.Height - $th - (Px 4) - $sh) / 2)
    [Windows.Forms.TextRenderer]::DrawText($G, $title, $FontBig, (New-Object Drawing.Rectangle($pad, $y, ($B.Width - 2 * $pad), $th)), $fg, 'Left, NoPrefix')
    [Windows.Forms.TextRenderer]::DrawText($G, $sub, $Font, (New-Object Drawing.Rectangle($pad, ($y + $th + (Px 4)), ($B.Width - 2 * $pad), $sh)), $(if ($B.Tag) { [Drawing.Color]::FromArgb(225, 255, 255, 255) } else { $Theme.Dim }), 'Left, WordBreak, NoPrefix')
    if ($B.Focused -and $B.ShowFocusCues) { $fp = New-RoundRect 3.5 3.5 ($B.Width - 7.5) ($B.Height - 7.5) (Px 6); $pen = New-Object Drawing.Pen($fg); $pen.DashStyle = 'Dot'; $G.DrawPath($pen, $fp); $pen.Dispose(); $fp.Dispose() }
}
$btnOld = New-Tile "This is my OLD PC`nPack up programs, files and settings onto a USB drive or external disk." $true
$btnNew = New-Tile "This is my NEW PC`nUnpack what you packed up on the old PC." $false
$startTiles.Controls.AddRange(@($btnOld, $btnNew))
$lblFound = New-Note
$lblFound.Dock = 'None'; $lblFound.Width = 674; $lblFound.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6); $lblFound.BackColor = $Theme.WarnBg; $lblFound.ForeColor = $Theme.WarnText
$btnFound = New-Button 'Unpack it'; $btnFound.Visible = $false; Set-Primary $btnFound
$startHow = New-Object Windows.Forms.Label
$startHow.AutoSize = $true; $startHow.MaximumSize = New-Object Drawing.Size(680, 0); $startHow.Margin = New-Object Windows.Forms.Padding(0, 14, 0, 0)
$startHow.Text = "How it works`n`n1.  On the old PC: start PC Move, choose ""This is my OLD PC"", tick what you want to take along and save it to a USB drive or external disk. PC Move puts a copy of itself there too.`n`n2.  On the new PC: plug in the drive, start PC-Move.exe from it and choose ""This is my NEW PC"". PC Move installs your programs, copies your files back and adds your Wi-Fi networks and settings. Nothing that is already on the new PC is overwritten.`n`n3.  The To do page lists what no program can move for you, such as signing in to your browser and OneDrive, with a button for each step."
$startNote = New-Object Windows.Forms.Label
$startNote.AutoSize = $true; $startNote.MaximumSize = New-Object Drawing.Size(680, 0); $startNote.ForeColor = $Theme.Dim; $startNote.Margin = New-Object Windows.Forms.Padding(0, 14, 0, 0)
$startNote.Text = 'Your old PC is not changed: PC Move only reads from it. Everything stays on your own drive - nothing is uploaded anywhere.'
$startFlow.Controls.AddRange(@($startTiles, $lblFound, $btnFound, $startHow, $startNote))
Set-PageLayout $pgStart $startFlow @()

# A move folder: "PC Move - <PC> - <date>" with pc-move.json inside, on any drive except this PC's own Windows drive,
# or the folder PC-Move.exe was started from.
function Find-Bundles {
    $roots = @()
    if ($RunningAsExe) { $here = Split-Path -Parent $SelfExe; $roots += $here; $roots += (Split-Path -Parent $here) }
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if ($d.IsReady -and $d.DriveType -in 'Removable', 'Fixed', 'Network' -and $d.Name -ne "$env:SystemDrive\") { $roots += $d.RootDirectory.FullName } } catch { }
    }
    $seen = @{}
    foreach ($r in $roots | Where-Object { $_ } | Select-Object -Unique) {
        foreach ($c in @($r) + @(Get-ChildItem -LiteralPath $r -Directory -Filter 'PC Move - *' -ErrorAction SilentlyContinue | ForEach-Object FullName)) {
            $mf = Join-Path $c 'pc-move.json'
            if (-not $seen[$c] -and (Test-Path -LiteralPath $mf)) { $seen[$c] = $true; Get-Item -LiteralPath $c }
        }
    }
}
function Update-Found {
    $b = @(Find-Bundles | Sort-Object LastWriteTime -Descending)
    $script:FoundBundle = if ($b) { $b[0].FullName } else { $null }
    if ($script:FoundBundle) {
        $lblFound.Text = "Found a move folder: $($script:FoundBundle)`nIs this the new PC? Unpack it."
        $btnFound.Visible = $true
    } else { $lblFound.Text = ''; $btnFound.Visible = $false }
}
$btnOld.Add_Click({ Show-Page $pgPack })
$btnNew.Add_Click({ Show-Page $pgUnpack; if (-not $script:Bundle) { if ($script:FoundBundle) { Open-Bundle $script:FoundBundle } else { Select-Bundle } } })
$btnFound.Add_Click({ Show-Page $pgUnpack; Open-Bundle $script:FoundBundle })

# ===========================================================================
# 2. Pack up (old PC)
# ===========================================================================
$pgPack = New-Page 'Pack up' 'Run this on your old PC. Tick what you want to take along, choose a USB drive or external disk, then click Pack up. Your old PC is not changed.'
$btnPack = New-Button 'Pack up checked items'
$btnDest = New-Button 'Choose where to save...'
$btnPackRescan = New-Button 'Look again'
$btnPackAll = New-Button 'Uncheck all'
$lblDest = New-Note
$lvPack = New-ListView $true @('What', 110, 'Item', 330, 'Size', 90, 'Note', 300)
$lblPack = New-Status
Set-PageLayout $pgPack $lvPack @((New-ButtonBar @($btnPack, $btnDest, $btnPackRescan, $btnPackAll)), $lblDest) $lblPack
$btnPack.Enabled = $false

# Everything on this PC that can move. Folder sizes take longest, so they come last.
$InventoryWork = {
    param($a)
    $out = [ordered]@{ Apps = @(); Manual = @(); NoWinget = $false; WingetError = $null; Steam = $false; Folders = @(); WiFi = @(); NoWiFi = $false; Bookmarks = @(); Firefox = $false; Chromium = @() }
    # --- Programs ---
    Set-JobProgress 'programs (asking winget, up to a minute)'
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    $listed = @()
    if ($wg) {
        $ex = Get-WingetExport $wg
        if ($ex.Cancelled) { return [pscustomobject]$out }
        $r = Invoke-Native $wg 'list --accept-source-agreements --disable-interactivity' 300
        $listed = @(ConvertFrom-WingetTable $r.Out)
        # winget cuts long names off ("Microsoft SQL Server 2016 Management Ob..."): Windows' own list has them in full.
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $arp = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | ForEach-Object { "$($_.DisplayName)".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($l in $listed) {
            if ($l.Name -notmatch "$([char]0x2026)$") { continue }
            $pre = $l.Name.TrimEnd([char]0x2026)
            $full = @($arp | Where-Object { $_.StartsWith($pre, 'OrdinalIgnoreCase') })
            if ($full.Count -eq 1) { $l.Name = $full[0] }
        }
        if ($ex.TimedOut -or $r.TimedOut) { $out.WingetError = 'winget took too long - click Look again to try once more.' }
        $names = @{}; foreach ($l in $listed) { if ($l.Id) { $names[$l.Id.TrimEnd([char]0x2026)] = $l.Name } }
        $out.Apps = @(foreach ($e in $ex.Ids) {
            # winget list cuts long ids off with "..."; match those by their start.
            $name = $names[$e.Id]
            if (-not $name) { foreach ($k in $names.Keys) { if ($k.Length -ge 8 -and $e.Id.StartsWith($k, 'OrdinalIgnoreCase')) { $name = $names[$k]; break } } }
            [pscustomobject]@{ Id = $e.Id; Source = $e.Source; Name = $(if ($name) { $name } else { $e.Id }) }
        })
        # Installed programs no source knows. Steam games come back through Steam, maker tools only fit that brand,
        # and Office shows up once per language.
        $have = @{}; foreach ($x in $out.Apps) { $have[$x.Name] = $true }
        $other = @($listed | Where-Object { -not $_.Source -and $_.Id -match '^ARP\\' -and -not $have[$_.Name] })
        $out.Steam = [bool]($other | Where-Object { $_.Id -match 'Steam App \d+' })
        $names = @($other | Where-Object { $_.Id -notmatch 'Steam App \d+' -and $_.Name -notmatch $a.NotProgramRx -and $_.Name -notmatch $a.MakerRx } | ForEach-Object {
            $n = $_.Name.Trim()
            if ($n -match '(?i)^Microsoft (365|Office|OneNote)') { 'Microsoft 365 (Office)' } else { $n -replace '\s+-\s+[a-z]{2}-[a-z]{2}$', '' }
        } | Sort-Object -Unique)
        # Many of them are in winget after all (installed another way, so winget doesn't link them): look each up by its exact name.
        $k = 0
        foreach ($n in $names) {
            $k++
            if (Test-Cancelled) { $out.Manual += $n; continue }
            if ($n -match [char]0x2026 -or $n -eq 'Microsoft 365 (Office)') { $out.Manual += $n; continue }   # still cut off, or not one program
            Set-JobProgress "looking up $n" $k $names.Count
            $hit = @()
            # The exact name first, then without the version and "(x64 en-US)": "Mozilla Firefox (x64 en-US)" is "Mozilla Firefox" in winget.
            $short = ($n -replace '\s*\([^)]*\)\s*$', '' -replace '\s+v?\d+(\.\d+)+.*$', '').Trim()
            foreach ($q in @($n) + @($short | Where-Object { $_ -ne $n -and $_.Length -ge 4 })) {
                $s = Invoke-Native $wg "search --name `"$($q -replace '"', '')`" --exact --source winget --accept-source-agreements --disable-interactivity" 30
                $hit = @(ConvertFrom-WingetTable $s.Out | Where-Object { $_.Name -eq $q -and $_.Id -and $_.Id -notmatch [char]0x2026 })
                if ($hit.Count -eq 1) { break }
            }
            if ($hit.Count -eq 1) { $out.Apps += [pscustomobject]@{ Id = $hit[0].Id; Source = 'winget'; Name = $n } } else { $out.Manual += $n }
        }
    } else {
        $out.NoWinget = $true
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $out.Manual = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName -and $_.DisplayName -notmatch $a.NotProgramRx -and $_.DisplayName -notmatch $a.MakerRx -and "$($_.UninstallString)" -notmatch 'steam://' } |
                        ForEach-Object { "$($_.DisplayName)".Trim() } | Sort-Object -Unique)
    }
    # --- Wi-Fi networks (exported to a temporary folder, read, and deleted straight away: the files hold passwords) ---
    Set-JobProgress 'Wi-Fi networks'
    $tmp = Join-Path $env:TEMP "pcmove-wifi-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $r = Invoke-Native "$env:windir\System32\netsh.exe" "wlan export profile folder=`"$tmp`" key=clear" 60
        $files = @(Get-ChildItem $tmp -Filter *.xml -ErrorAction SilentlyContinue)
        if (-not $files -and $r.Code -ne 0) { $out.NoWiFi = $true }
        $out.WiFi = @(foreach ($f in $files) {
            try {
                $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
                $x = [xml]$text
                $sec = $x.WLANProfile.MSM.security
                $auth = "$($sec.authEncryption.authentication)"
                [pscustomobject]@{ Name = "$($x.WLANProfile.name)"; Xml = $text; Auth = $auth
                                   HasKey = [bool]$sec.sharedKey.keyMaterial; Open = ($auth -eq 'open'); Work = ($auth -in 'WPA', 'WPA2', 'WPA3', 'WPA3ENT', 'WPA3ENT192') }
            } catch { }
        })
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    # --- Bookmarks: Chromium browsers keep them as JSON per profile; Firefox uses a database (sign in instead) ---
    Set-JobProgress 'bookmarks'
    $browsers = @(
        @{ Name = 'Chrome'; Dir = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
        @{ Name = 'Edge'; Dir = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
        @{ Name = 'Brave'; Dir = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
        @{ Name = 'Vivaldi'; Dir = "$env:LOCALAPPDATA\Vivaldi\User Data" }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path -LiteralPath $b.Dir)) { continue }
        $out.Chromium += $b.Name
        $names = @{}
        try { $ls = Get-Content -LiteralPath (Join-Path $b.Dir 'Local State') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; foreach ($p in $ls.profile.info_cache.PSObject.Properties) { $names[$p.Name] = "$($p.Value.name)" } } catch { }
        foreach ($pd in Get-ChildItem -LiteralPath $b.Dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }) {
            $bf = Join-Path $pd.FullName 'Bookmarks'
            if (-not (Test-Path -LiteralPath $bf)) { continue }
            try {
                $conv = ConvertTo-BookmarkHtml (Get-Content -LiteralPath $bf -Raw -Encoding UTF8 | ConvertFrom-Json)
                if ($conv.Count) {
                    $pn = if ($names[$pd.Name]) { $names[$pd.Name] } else { $pd.Name }
                    $out.Bookmarks += [pscustomobject]@{ Browser = $b.Name; Profile = $pn; Count = $conv.Count; Html = $conv.Html }
                }
            } catch { }
        }
    }
    $out.Firefox = Test-Path -LiteralPath "$env:APPDATA\Mozilla\Firefox\Profiles"
    # --- Folder sizes ---
    $i = 0
    foreach ($f in $a.Folders) {
        $i++
        if (Test-Cancelled) { break }
        Set-JobProgress "size of $($f.Name)" $i $a.Folders.Count
        $bytes = 0.0; $n = 0
        if (-not $f.OneDrive) { foreach ($x in Get-FilesSafe $f.Path) { $bytes += $x.Length; $n++; if (($n % 2000) -eq 0 -and (Test-Cancelled)) { break } } }
        $out.Folders += [pscustomobject]@{ Key = $f.Key; Name = $f.Name; Path = $f.Path; OneDrive = $f.OneDrive; Bytes = $bytes; Files = $n }
    }
    [pscustomobject]$out
}
function Start-Inventory {
    $btnPack.Enabled = $false; $btnPackRescan.Enabled = $false
    $lvPack.Items.Clear()
    $lblPack.Text = 'Looking at what is on this PC (about a minute)...'
    Start-Bg -Label 'Looking at this PC' -Cancellable $InventoryWork @{ Folders = @(Get-PersonalFolders); NotProgramRx = $NotProgramRx; MakerRx = $MakerRx } {
        param($r, $state)
        $r = $r[0]
        $btnPackRescan.Enabled = $true
        if (-not $r) { $lblPack.Text = 'Could not look at this PC - click Look again.'; return }
        $script:Inventory = $r
        Show-Inventory $r ([bool]$state.Cancel)
    }
}
function Show-Inventory($R, [bool]$Stopped) {
    $lvPack.BeginUpdate(); $lvPack.Items.Clear()
    $rows = @()
    foreach ($a in $R.Apps) {
        $note = if ($a.Id -match $FrameworkRx -or $a.Name -match $NotProgramRx) { 'comes with Windows or other programs' }
                elseif ($a.Name -match $MakerRx -or $a.Id -match $MakerRx) { 'from the PC maker - only for a PC of the same brand' }
                elseif ($a.Source -eq 'msstore') { 'from the Microsoft Store' } else { 'installed again on the new PC' }
        $rows += @{ Kind = 'App'; Item = $a.Name; Size = ''; Note = $note; On = $note -in 'from the Microsoft Store', 'installed again on the new PC'; Data = $a }
    }
    foreach ($f in $R.Folders) {
        $note = if ($f.OneDrive) { 'already in OneDrive - it comes back when you sign in on the new PC' }
                elseif (-not $f.Files) { 'empty' }
                elseif ($f.Key -eq 'Downloads') { 'often old installers - tick it if you want it' }
                else { "$($f.Files) files" }
        $rows += @{ Kind = 'Folder'; Item = $f.Name; Size = $(if ($f.OneDrive) { '' } else { Format-Size $f.Bytes }); Bytes = $f.Bytes; Note = $note; On = (-not $f.OneDrive -and $f.Files -gt 0 -and $f.Key -ne 'Downloads'); Data = $f; Off = ($f.OneDrive -or -not $f.Files) }
    }
    foreach ($w in $R.WiFi) {
        $note = if ($w.Open) { 'open network, no password' }
                elseif ($w.Work) { 'work or school network - you sign in again on the new PC' }
                elseif ($w.HasKey) { 'with its password' }
                else { 'without its password - restart PC Move as administrator to include it' }
        $rows += @{ Kind = 'WiFi'; Item = $w.Name; Size = ''; Note = $note; On = -not $w.Work; Data = $w }
    }
    foreach ($s in $SettingsCatalog) {
        $v = Get-RegValue $s.P $s.N
        if ($null -eq $v) { continue }
        $rows += @{ Kind = 'Setting'; Item = $s.Name; Size = ''; Note = (Get-SettingText $s $v); On = $true; Data = @{ Key = $s.Key; Value = $v } }
    }
    $wp = Get-WallpaperFile
    if ($wp) { $rows += @{ Kind = 'Wallpaper'; Item = 'Desktop background'; Size = (Format-Size (Get-Item -LiteralPath $wp).Length); Note = 'your own picture'; On = $true; Data = $wp } }
    foreach ($b in $R.Bookmarks) {
        $rows += @{ Kind = 'Bookmarks'; Item = "$($b.Browser) ($($b.Profile))"; Size = ''; Note = "$($b.Count) bookmarks - you import them in the browser on the new PC"; On = $true; Data = $b }
    }
    foreach ($x in $rows | Sort-Object { $KindOrder[$_.Kind] }, { -not $_.On }, { $_.Item }) {
        $it = Add-Row $lvPack @($KindName[$x.Kind], $x.Item, $x.Size, $x.Note) $x $x.On
        if ($x.Off -or ($x.Kind -eq 'App' -and -not $x.On)) { $it.ForeColor = $Theme.Muted }
        $it.ToolTipText = T $x.Note
    }
    $lvPack.EndUpdate()
    $msg = @()
    if ($Stopped) { $msg += 'Stopped - the list may be incomplete.' }
    if ($R.NoWinget) { $msg += 'winget is missing on this PC, so programs go on the to-do list instead (install "App Installer" from the Microsoft Store to move them automatically).' }
    if ($R.WingetError) { $msg += $R.WingetError }
    if ($R.Manual.Count) { $msg += "$($R.Manual.Count) program(s) are not in winget - they go on the new PC's to-do list." }
    $lblPack.Text = if ($msg) { $msg -join '  ' } else { 'Tick what you want to take along.' }
    Update-PackSummary
}
function Get-PackPicked { @($lvPack.CheckedItems | ForEach-Object { $_.Tag }) }
function Update-PackSummary {
    $picked = Get-PackPicked
    $bytes = ($picked | Where-Object { $_.Kind -eq 'Folder' } | ForEach-Object { [double]$_.Bytes } | Measure-Object -Sum).Sum
    $script:PackBytes = [double]$bytes
    $btnPack.Enabled = [bool]$picked -and [bool]$script:Inventory -and -not ($script:Jobs | Where-Object { $_.Label -eq 'Packing up' })
    $btnPackAll.Text = if ($picked) { 'Uncheck all' } else { 'Check all' }
    if (-not $script:PackDest) { $lblDest.Text = "Selected: $($picked.Count) item(s), $(Format-Size $bytes) of files.  Next: choose where to save - a USB drive or external disk with enough free space."; return }
    $free = try { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:PackDest))).AvailableFreeSpace } catch { 0 }
    $lblDest.Text = "Saving to: $($script:PackDest)  ($(Format-Size $free) free)`nSelected: $($picked.Count) item(s), $(Format-Size $bytes) of files." +
                    $(if ($free -and $free -lt $bytes * 1.02 + 50MB) { "`nNot enough free space - untick some folders or choose a bigger drive." } else { '' })
}
$lvPack.Add_ItemChecked({ if (-not $script:PackSummaryQueued) { $script:PackSummaryQueued = $true; $form.BeginInvoke([Action]{ $script:PackSummaryQueued = $false; Update-PackSummary }) | Out-Null } })
# One button: unticks everything when something is ticked, otherwise ticks everything that can move.
$btnPackAll.Add_Click({ $on = -not $lvPack.CheckedItems.Count; foreach ($it in $lvPack.Items) { $it.Checked = $on -and -not $it.Tag.Off } })
$btnPackRescan.Add_Click({ Start-Inventory })
function Select-PackDest {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = T 'Choose a USB drive, external disk or network folder. PC Move makes a new folder in it.'
    $usb = @([IO.DriveInfo]::GetDrives() | Where-Object { try { $_.IsReady -and $_.DriveType -eq 'Removable' } catch { $false } })
    $dlg.SelectedPath = if ($script:PackDest) { $script:PackDest } elseif ($usb) { $usb[0].RootDirectory.FullName } else { '' }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $p = $dlg.SelectedPath
    if ([IO.Path]::GetPathRoot($p) -eq "$env:SystemDrive\") {
        if ((Show-Msg "That is on this PC's own drive ($env:SystemDrive), which stays behind when you move. Choose a USB drive, an external disk or a network folder instead?`n`nYes = choose again, No = use it anyway (for example to copy it later)." 'YesNo' 'Warning') -eq 'Yes') { Select-PackDest; return }
    }
    $script:PackDest = $p
    Update-PackSummary
}
$btnDest.Add_Click({ Select-PackDest })

$PackWork = {
    param($a)
    $dir = $a.Dir
    $res = [ordered]@{ Dir = $dir; Failed = @(); Copied = 0.0; Cancelled = $false; Error = $null }
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        $m = $a.Manifest
        $total = [Math]::Max(1.0, [double]$a.Bytes)
        $done = 0.0
        # Small things first, so a full drive or Cancel leaves the useful part.
        if ($a.Exe) { Set-JobProgress 'PC Move itself'; Copy-Item -LiteralPath $a.Exe -Destination (Join-Path $dir 'PC-Move.exe') -Force -ErrorAction SilentlyContinue }
        if (@($a.WiFi).Count) {
            New-Item -ItemType Directory -Force (Join-Path $dir 'WiFi') | Out-Null
            $n = 0
            $m.WiFi = @(foreach ($w in $a.WiFi) {
                $n++; $f = "WiFi\network-$n.xml"
                [IO.File]::WriteAllText((Join-Path $dir $f), $w.Xml, (New-Object Text.UTF8Encoding($false)))
                [ordered]@{ Name = $w.Name; File = $f; HasKey = $w.HasKey; Open = $w.Open }
            })
        }
        if ($a.Wallpaper) {
            Set-JobProgress 'desktop background'
            New-Item -ItemType Directory -Force (Join-Path $dir 'Settings') | Out-Null
            $ext = [IO.Path]::GetExtension($a.Wallpaper); if (-not $ext) { $ext = '.jpg' }
            $f = "Settings\desktop-background$ext"
            Copy-Item -LiteralPath $a.Wallpaper -Destination (Join-Path $dir $f) -Force
            $m.Wallpaper = $f
        }
        if (@($a.Bookmarks).Count) {
            New-Item -ItemType Directory -Force (Join-Path $dir 'Bookmarks') | Out-Null
            $m.Bookmarks = @(foreach ($b in $a.Bookmarks) {
                $safe = ("$($b.Browser) - $($b.Profile)" -replace '[\\/:*?"<>|]', '_')
                $f = "Bookmarks\$safe.html"
                [IO.File]::WriteAllText((Join-Path $dir $f), $b.Html, (New-Object Text.UTF8Encoding($false)))
                [ordered]@{ Browser = $b.Browser; Profile = $b.Profile; Count = $b.Count; File = $f }
            })
        }
        $m.Folders = @()
        foreach ($f in $a.Folders) {
            if (Test-Cancelled) { break }
            $rel = "Files\$($f.Key)"
            $c = Invoke-Copy $f.Path (Join-Path $dir $rel) "copying $($f.Name)" $done $total
            $done += $c.Bytes; $res.Copied += $c.Bytes
            if (-not $c.Ok) { $res.Failed += $f.Name }
            $m.Folders += [ordered]@{ Key = $f.Key; Name = $f.Name; Dir = $rel; Bytes = $c.Bytes; Files = $c.Files; Complete = ($c.Ok -and -not $c.Cancelled) }
        }
        $res.Cancelled = Test-Cancelled
        $m.Complete = -not $res.Cancelled
        # The list of contents is written last: a folder without it was never finished.
        $m | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'pc-move.json') -Encoding UTF8
        # A short note for anyone who finds the drive.
        Set-Content -LiteralPath (Join-Path $dir 'READ ME.txt') -Encoding UTF8 -Value @(
            "This folder was made by PC Move on $($m.From.Pc) ($($m.Created))."
            'To move everything to a new PC: start PC-Move.exe in this folder on the new PC and choose "This is my NEW PC".'
            ''
            'The WiFi folder holds Wi-Fi passwords. Delete this whole folder when the move is done.'
        )
    } catch { $res.Error = $_.Exception.Message }
    [pscustomobject]$res
}
function Start-Pack {
    $picked = Get-PackPicked
    if (-not $picked) { Show-Msg 'Tick at least one item first.' | Out-Null; return }
    if (-not $script:PackDest) { Select-PackDest; if (-not $script:PackDest) { return } }
    $free = try { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:PackDest))).AvailableFreeSpace } catch { 0 }
    if ($free -and $free -lt $script:PackBytes * 1.02 + 50MB) {
        Show-Msg "There is not enough free space on $($script:PackDest): $(Format-Size $script:PackBytes) needed, $(Format-Size $free) free.`n`nUntick some folders or choose another drive." 'OK' 'Warning' | Out-Null; return
    }
    $wifi = @($picked | Where-Object { $_.Kind -eq 'WiFi' -and $_.Data.HasKey })
    $q = "Pack up $($picked.Count) item(s) ($(Format-Size $script:PackBytes) of files) to:`n$($script:PackDest)?" +
         $(if ($wifi) { "`n`nThe Wi-Fi passwords are saved as plain text in the move folder. Keep the drive safe, and delete the folder when the move is done." } else { '' })
    if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $prod = if ([int]$cv.CurrentBuild -ge 22000) { "$($cv.ProductName)" -replace 'Windows 10', 'Windows 11' } else { "$($cv.ProductName)" }
    $inv = $script:Inventory
    $manifest = [ordered]@{
        Format = 'PC Move bundle'; Version = $AppVersion; Created = (Get-Date).ToString('s'); Complete = $false
        From = [ordered]@{ Pc = $env:COMPUTERNAME; User = $env:USERNAME; Windows = "$prod $($cv.DisplayVersion)" }
        Apps = @($picked | Where-Object Kind -eq 'App' | ForEach-Object { [ordered]@{ Name = $_.Data.Name; Id = $_.Data.Id; Source = $_.Data.Source } })
        Manual = @($inv.Manual)
        Settings = @($picked | Where-Object Kind -eq 'Setting' | ForEach-Object { [ordered]@{ Key = $_.Data.Key; Value = $_.Data.Value } })
        WiFi = @(); Wallpaper = $null; Bookmarks = @(); Folders = @()
        OneDrive = @($inv.Folders | Where-Object OneDrive | ForEach-Object Name)
        Firefox = [bool]$inv.Firefox; Chromium = @($inv.Chromium); Steam = [bool]$inv.Steam
    }
    $dir = Join-Path $script:PackDest ("PC Move - $env:COMPUTERNAME - " + (Get-Date).ToString('yyyy-MM-dd HHmm'))
    $arg = @{ Dir = $dir; Manifest = $manifest; Bytes = $script:PackBytes
              Exe = $(if ($RunningAsExe) { $SelfExe } else { $null })
              WiFi = @($picked | Where-Object Kind -eq 'WiFi' | ForEach-Object Data)
              Wallpaper = @($picked | Where-Object Kind -eq 'Wallpaper' | ForEach-Object Data)[0]
              Bookmarks = @($picked | Where-Object Kind -eq 'Bookmarks' | ForEach-Object Data)
              Folders = @($picked | Where-Object Kind -eq 'Folder' | ForEach-Object Data) }
    $btnPack.Enabled = $false; $btnDest.Enabled = $false; $btnPackRescan.Enabled = $false
    $lblPack.Text = 'Packing up...'
    Start-Bg -Label 'Packing up' -Cancellable $PackWork $arg {
        param($r)
        $r = $r[0]
        $btnDest.Enabled = $true; $btnPackRescan.Enabled = $true; Update-PackSummary
        if (-not $r -or $r.Error) {
            $lblPack.Text = "Packing up failed: $($r.Error)"
            Show-Msg "Packing up failed:`n$($r.Error)" 'OK' 'Warning' | Out-Null; return
        }
        Write-Log "Packed up to $($r.Dir) ($(Format-Size $r.Copied) of files)$(if ($r.Cancelled) { ' - stopped' })"
        if ($r.Cancelled) { $lblPack.Text = "Stopped. What was copied so far is in $($r.Dir) - click Pack up to start again."; return }
        $lblPack.Text = "Done: $($r.Dir)"
        $msg = "Everything is packed up in:`n$($r.Dir)" +
               $(if ($r.Failed) { "`n`nSome files in $($r.Failed -join ', ') could not be copied - usually because a program had them open. Close your programs and click Pack up again to try once more." } else { '' }) +
               "`n`nNext: take the drive to your new PC, open this folder there and start PC-Move.exe, then choose ""This is my NEW PC""."
        Show-Msg $msg | Out-Null
        Start-Process explorer.exe "`"$($r.Dir)`""
    }
}
$btnPack.Add_Click({ Start-Pack })

# ===========================================================================
# 3. Unpack (new PC)
# ===========================================================================
$pgUnpack = New-Page 'Unpack' 'Run this on your new PC. Open the move folder from your old PC, tick what you want, then click Unpack. Files that are already here are never overwritten.'
$btnUnpack = New-Button 'Unpack checked items'
$btnOpenBundle = New-Button 'Open a move folder...'
$btnUnAll = New-Button 'Uncheck all'
$lblBundle = New-Note
$lvUnpack = New-ListView $true @('What', 110, 'Item', 330, 'Size', 90, 'Status', 300)
$lblUnpack = New-Status
Set-PageLayout $pgUnpack $lvUnpack @((New-ButtonBar @($btnUnpack, $btnOpenBundle, $btnUnAll)), $lblBundle) $lblUnpack
$btnUnpack.Enabled = $false
$lblBundle.Text = 'No move folder open yet. Plug in the drive from your old PC and click "Open a move folder...".'

function Select-Bundle {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = T 'Choose the "PC Move - ..." folder you made on your old PC.'
    if ($script:FoundBundle) { $dlg.SelectedPath = $script:FoundBundle }
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $p = $dlg.SelectedPath
    # Picked the drive or the folder above it: take the newest move folder inside.
    if (-not (Test-Path -LiteralPath (Join-Path $p 'pc-move.json'))) {
        $in = @(Get-ChildItem -LiteralPath $p -Directory -Filter 'PC Move - *' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pc-move.json') } | Sort-Object LastWriteTime -Descending)
        if ($in) { $p = $in[0].FullName }
    }
    Open-Bundle $p
}
$btnOpenBundle.Add_Click({ Select-Bundle })
function Read-Bundle([string]$Dir) {
    $mf = Join-Path $Dir 'pc-move.json'
    if (-not (Test-Path -LiteralPath $mf)) { return $null }
    try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ($m.Format -ne 'PC Move bundle') { return $null }
    $m
}
# What this PC already has, so it isn't done twice: installed programs (winget) and Wi-Fi networks.
$HaveWork = {
    $out = [ordered]@{ Ids = @(); NoWinget = $false; WiFi = @() }
    Set-JobProgress 'programs already installed (asking winget)'
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($wg) { $out.Ids = @((Get-WingetExport $wg).Ids | ForEach-Object Id) } else { $out.NoWinget = $true }
    Set-JobProgress 'Wi-Fi networks'
    $tmp = Join-Path $env:TEMP "pcmove-have-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        [void](Invoke-Native "$env:windir\System32\netsh.exe" "wlan export profile folder=`"$tmp`"" 60)   # without key=clear: names only
        $out.WiFi = @(foreach ($f in Get-ChildItem $tmp -Filter *.xml -ErrorAction SilentlyContinue) { try { "$(([xml][IO.File]::ReadAllText($f.FullName)).WLANProfile.name)" } catch { } })
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    [pscustomobject]$out
}
function Open-Bundle([string]$Dir) {
    $m = Read-Bundle $Dir
    if (-not $m) { Show-Msg "That folder is not a PC Move folder (it has no pc-move.json).`n`nChoose the folder whose name starts with ""PC Move - "", on the drive you used on the old PC." 'OK' 'Warning' | Out-Null; return }
    $script:Bundle = @{ Dir = $Dir; M = $m }
    $lblBundle.Text = "Move folder: $Dir`nFrom $($m.From.Pc) ($($m.From.Windows)), packed up on $(([datetime]$m.Created).ToString('f'))." +
                      $(if (-not $m.Complete) { "`nPacking up did not finish on the old PC, so some files may be missing." } else { '' })
    $lvUnpack.Items.Clear(); $btnUnpack.Enabled = $false
    $lblUnpack.Text = 'Checking what this PC already has (up to a minute)...'
    Update-Todo
    Start-Bg -Label 'Checking this PC' $HaveWork $null {
        param($r)
        $script:Have = $r[0]
        Show-Unpack
    }
}
function Show-Unpack {
    $m = $script:Bundle.M; $dir = $script:Bundle.Dir; $have = $script:Have
    $ids = @{}; foreach ($i in @($have.Ids)) { $ids[$i] = $true }
    $nets = @{}; foreach ($n in @($have.WiFi)) { $nets[$n] = $true }
    $folders = @{}; foreach ($f in Get-PersonalFolders) { $folders[$f.Key] = $f }
    $lvUnpack.BeginUpdate(); $lvUnpack.Items.Clear()
    foreach ($a in @($m.Apps)) {
        $x = @{ Kind = 'App'; Data = $a }
        if ($have.NoWinget) { $it = Add-Row $lvUnpack @('Program', $a.Name, '', '') $x $false; Set-RowStatus $it 3 'needs winget - see the note below' $Theme.Muted }
        elseif ($ids[$a.Id]) { $x.Done = $true; $it = Add-Row $lvUnpack @('Program', $a.Name, '', '') $x $false; Set-RowStatus $it 3 'already on this PC' $Theme.Muted }
        else { $it = Add-Row $lvUnpack @('Program', $a.Name, '', '') $x $true; Set-RowStatus $it 3 $(if ($a.Source -eq 'msstore') { 'will be installed from the Microsoft Store' } else { 'will be installed' }) $Theme.Dim }
    }
    foreach ($f in @($m.Folders)) {
        $to = $folders[$f.Key]
        if (-not $to -or -not (Test-Path -LiteralPath (Join-Path $dir $f.Dir))) { continue }
        $x = @{ Kind = 'Folder'; Data = $f; To = $to.Path }
        $it = Add-Row $lvUnpack @('Folder', "$($f.Name)  ->  $($to.Path)", (Format-Size $f.Bytes), '') $x $true
        Set-RowStatus $it 3 $(if ($to.OneDrive) { 'goes into OneDrive on this PC; files already here are skipped' } else { 'files already here are skipped' }) $Theme.Dim
    }
    foreach ($w in @($m.WiFi)) {
        $x = @{ Kind = 'WiFi'; Data = $w }
        if ($nets[$w.Name]) { $x.Done = $true; $it = Add-Row $lvUnpack @('Wi-Fi', $w.Name, '', '') $x $false; Set-RowStatus $it 3 'already on this PC' $Theme.Muted }
        else { $it = Add-Row $lvUnpack @('Wi-Fi', $w.Name, '', '') $x $true; Set-RowStatus $it 3 $(if ($w.HasKey -or $w.Open) { 'will be added' } else { 'will be added - Windows asks the password once' }) $Theme.Dim }
    }
    foreach ($s in @($m.Settings)) {
        $c = $SettingsCatalog | Where-Object Key -eq $s.Key | Select-Object -First 1
        if (-not $c) { continue }   # a Windows 11 setting on Windows 10
        $now = Get-RegValue $c.P $c.N
        $x = @{ Kind = 'Setting'; Data = $s; Catalog = $c }
        if ("$now" -eq "$($s.Value)") { $x.Done = $true; $it = Add-Row $lvUnpack @('Setting', $c.Name, '', '') $x $false; Set-RowStatus $it 3 "already $(Get-SettingText $c $now)" $Theme.Muted }
        else { $it = Add-Row $lvUnpack @('Setting', $c.Name, '', '') $x $true; Set-RowStatus $it 3 "$(Get-SettingText $c $now) -> $(Get-SettingText $c $s.Value)" $Theme.Dim }
    }
    if ($m.Wallpaper -and (Test-Path -LiteralPath (Join-Path $dir $m.Wallpaper))) {
        $it = Add-Row $lvUnpack @('Setting', 'Desktop background', '', '') @{ Kind = 'Wallpaper'; Data = $m.Wallpaper } $true
        Set-RowStatus $it 3 'your picture from the old PC' $Theme.Dim
    }
    foreach ($b in @($m.Bookmarks)) {
        $it = Add-Row $lvUnpack @('Bookmarks', "$($b.Browser) ($($b.Profile))", '', '') @{ Kind = 'Bookmarks'; Data = $b } $true
        Set-RowStatus $it 3 "$($b.Count) bookmarks - saved to Documents, then you import them (see To do)" $Theme.Dim
    }
    $lvUnpack.EndUpdate()
    $todo = @(Get-TodoItems).Count
    $lblUnpack.Text = if ($have.NoWinget) { 'winget is missing on this PC, so programs cannot be installed automatically. Install "App Installer" from the Microsoft Store (Settings > Open the Store page), then open the move folder again.' }
                      elseif ($lvUnpack.CheckedItems.Count) { "$($lvUnpack.CheckedItems.Count) item(s) ready to unpack. Afterwards, the To do page has $todo step(s) to do yourself." }
                      else { "Nothing left to unpack - everything is already on this PC. The To do page has $todo step(s) to do yourself." }
    $btnUnpack.Enabled = $lvUnpack.CheckedItems.Count -gt 0
}
$lvUnpack.Add_ItemChecked({
    if (-not $script:Busy) { $btnUnpack.Enabled = $lvUnpack.CheckedItems.Count -gt 0 }
    $t = if ($lvUnpack.CheckedItems.Count) { 'Uncheck all' } else { 'Check all' }
    if ($btnUnAll.Text -ne (T $t)) { $btnUnAll.Text = $t }
})
$btnUnAll.Add_Click({ $on = -not $lvUnpack.CheckedItems.Count; foreach ($it in $lvUnpack.Items) { $it.Checked = $on -and -not $it.Tag.Done -and -not ($it.Tag.Kind -eq 'App' -and $script:Have.NoWinget) } })

# Order: quick things first (settings, Wi-Fi, bookmarks), then files, then programs (the slowest).
$UnpackWork = {
    param($a)
    $results = @()
    $all = @($a.Items).Count; $n = 0
    $total = [Math]::Max(1.0, [double](($a.Items | Where-Object Kind -eq 'Folder' | ForEach-Object { [double]$_.Data.Bytes } | Measure-Object -Sum).Sum))
    $done = 0.0
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    foreach ($i in $a.Items) {
        $n++
        if (Test-Cancelled) { $results += [pscustomobject]@{ Key = $i.Key; Ok = $false; Msg = 'not done - you pressed Cancel' }; continue }
        $r = [pscustomobject]@{ Key = $i.Key; Ok = $true; Msg = 'done'; Undo = $null; Bytes = 0 }
        try {
            switch ($i.Kind) {
                'Setting' {
                    Set-JobProgress "setting: $($i.Name)" $n $all
                    $c = $i.Catalog
                    $old = try { (Get-ItemProperty -LiteralPath $c.P -Name $c.N -ErrorAction Stop).($c.N) } catch { $null }
                    if (-not (Test-Path -LiteralPath $c.P)) { New-Item -Path $c.P -Force | Out-Null }
                    $t = if ($c.T) { $c.T } else { 'DWord' }
                    Set-ItemProperty -LiteralPath $c.P -Name $c.N -Value $i.Data.Value -Type $t
                    if ($c.N -eq 'MouseSensitivity') { [void][PcMove.Native]::SystemParametersInfoPtr(0x71, 0, [IntPtr][int]$i.Data.Value, 3) }   # SPI_SETMOUSESPEED, now
                    if ($c.N -eq 'DoubleClickSpeed') { [void][PcMove.Native]::SystemParametersInfoPtr(0x20, [int]$i.Data.Value, [IntPtr]::Zero, 3) }   # SPI_SETDOUBLECLICKTIME
                    $r.Undo = @{ P = $c.P; N = $c.N; Old = $old; T = $t; Name = $c.Name }
                }
                'Wallpaper' {
                    Set-JobProgress 'desktop background' $n $all
                    $src = Join-Path $a.Dir $i.Data
                    $toDir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'From the old PC'
                    New-Item -ItemType Directory -Force $toDir | Out-Null
                    $to = Join-Path $toDir ('Desktop background' + [IO.Path]::GetExtension($src))
                    Copy-Item -LiteralPath $src -Destination $to -Force
                    $old = try { (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction Stop).WallPaper } catch { $null }
                    if (-not [PcMove.Native]::SystemParametersInfo(20, 0, $to, 3)) { throw 'Windows did not accept the picture' }   # SPI_SETDESKWALLPAPER
                    $r.Undo = @{ Wallpaper = $old; Name = 'Desktop background' }
                }
                'WiFi' {
                    Set-JobProgress "Wi-Fi: $($i.Name)" $n $all
                    $x = Invoke-Native "$env:windir\System32\netsh.exe" "wlan add profile filename=`"$(Join-Path $a.Dir $i.Data.File)`" user=current" 60
                    if ($x.Code -ne 0) { $r.Ok = $false; $r.Msg = $(if ($x.Out -match '\S') { Get-LastLine $x.Out } else { 'Windows did not accept it' }) }
                }
                'Bookmarks' {
                    Set-JobProgress "bookmarks: $($i.Name)" $n $all
                    $toDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Bookmarks from the old PC'
                    New-Item -ItemType Directory -Force $toDir | Out-Null
                    Copy-Item -LiteralPath (Join-Path $a.Dir $i.Data.File) -Destination $toDir -Force
                    $r.Msg = 'saved to Documents - import it next (see To do)'
                }
                'Folder' {
                    $c = Invoke-Copy (Join-Path $a.Dir $i.Data.Dir) $i.To "copying $($i.Data.Name)" $done $total -SkipExisting
                    $done += [double]$i.Data.Bytes; $r.Bytes = $c.Bytes
                    $r.Ok = $c.Ok -and -not $c.Cancelled
                    $r.Msg = if ($c.Cancelled) { 'stopped - you pressed Cancel' } elseif (-not $c.Ok) { 'some files could not be copied' } elseif ($c.Files) { "$($c.Files) file(s) copied" } else { 'everything was already here' }
                }
                'App' {
                    Set-JobProgress "installing $($i.Name) ($n of $all)" $n $all
                    $src = if ($i.Data.Source -eq 'msstore') { 'msstore' } else { 'winget' }
                    $x = Invoke-Native $wg "install --id `"$($i.Data.Id)`" --exact --source $src --silent --accept-package-agreements --accept-source-agreements --disable-interactivity" 1800
                    # -1978335189 = already installed and up to date
                    $r.Ok = $x.Code -in 0, -1978335189, -1978335135
                    $r.Msg = if ($x.Cancelled) { 'stopped - you pressed Cancel' } elseif ($x.TimedOut) { 'took longer than 30 minutes - stopped' } elseif ($x.Code -in -1978335189, -1978335135) { 'already on this PC' } elseif ($r.Ok) { 'installed' } else { Get-LastLine $x.Out }
                }
            }
        } catch { $r.Ok = $false; $r.Msg = $_.Exception.Message }
        $results += $r
    }
    # Tell open windows that colours and Explorer options changed (HWND_BROADCAST, WM_SETTINGCHANGE).
    if ($a.Items | Where-Object Kind -eq 'Setting') {
        $res = [IntPtr]::Zero
        foreach ($area in 'ImmersiveColorSet', 'Policy', 'TraySettings') { [void][PcMove.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, $area, 2, 3000, [ref]$res) }
    }
    $results
}
function Start-Unpack {
    $picked = @($lvUnpack.CheckedItems)
    if (-not $picked) { Show-Msg 'Tick at least one item first.' | Out-Null; return }
    $apps = @($picked | Where-Object { $_.Tag.Kind -eq 'App' }).Count
    $q = "Unpack $($picked.Count) item(s) onto this PC?`n`nFiles that are already here are not overwritten. Settings can be undone in Settings." +
         $(if ($apps -and -not $IsAdmin) { "`n`n$apps program(s) will be installed. Some installers ask for permission (a Windows prompt) - to avoid that, click No and use ""Run as administrator"" first." } elseif ($apps) { "`n`nInstalling $apps program(s) can take a while; you can keep using the PC." })
    if ((Show-Msg $q 'YesNo' 'Question') -ne 'Yes') { return }
    $k = 0
    $items = foreach ($it in $picked | Sort-Object { @{ Setting = 1; Wallpaper = 2; WiFi = 3; Bookmarks = 4; Folder = 5; App = 6 }[$_.Tag.Kind] }) {
        $k++; $it.Tag.Key = $k
        Set-RowStatus $it 3 'waiting...' $Theme.Dim
        @{ Key = $k; Kind = $it.Tag.Kind; Name = $it.SubItems[1].Text; Data = $it.Tag.Data; To = $it.Tag.To; Catalog = $it.Tag.Catalog }
    }
    $script:Busy = $true
    $btnUnpack.Enabled = $false; $btnOpenBundle.Enabled = $false
    $lblUnpack.Text = 'Unpacking...'
    Start-Bg -Label 'Unpacking' -Cancellable $UnpackWork @{ Dir = $script:Bundle.Dir; Items = @($items) } {
        param($res)
        $script:Busy = $false
        $btnOpenBundle.Enabled = $true
        $undo = @(Get-UndoList)
        $ok = 0; $bad = 0
        foreach ($r in $res) {
            $it = $lvUnpack.Items | Where-Object { $_.Tag.Key -eq $r.Key } | Select-Object -First 1
            if (-not $it) { continue }
            $it.Checked = $false
            if ($r.Ok) { $ok++; $it.Tag.Done = $true; Set-RowStatus $it 3 $r.Msg $Theme.Good } else { $bad++; Set-RowStatus $it 3 $r.Msg $Theme.Bad }
            if ($r.Ok -and $r.Undo) { $undo += [pscustomobject]$r.Undo }
            Write-Log "Unpacked $($it.Tag.Kind) $($it.SubItems[1].Text): $(if ($r.Ok) { 'ok' } else { 'failed' }) - $($r.Msg)"
        }
        Save-UndoList $undo; Update-UndoButton
        $btnUnpack.Enabled = $lvUnpack.CheckedItems.Count -gt 0
        $todo = @(Get-TodoItems | Where-Object { -not $_.Done }).Count
        $lblUnpack.Text = "$ok item(s) done$(if ($bad) { ", $bad did not work (see the Status column) - tick them and click Unpack to try again" })."
        Update-Todo
        $msg = "Unpacked: $ok item(s) done$(if ($bad) { ", $bad did not work - see the Status column" })." +
               $(if (@($res | Where-Object { $_.Undo -and $_.Undo.N -in 'TaskbarAl', 'HideFileExt', 'Hidden', 'LaunchTo', 'SearchboxTaskbarMode' })) { "`n`nSome Explorer and taskbar settings show after you sign out and back in." } else { '' }) +
               $(if ($todo) { "`n`nNext: the To do page has $todo step(s) to do yourself." } else { '' })
        Show-Msg $msg | Out-Null
        if ($todo) { Show-Page $pgTodo }
    }
}
$btnUnpack.Add_Click({ Start-Unpack })

# ===========================================================================
# 4. To do (new PC): what no program can move
# ===========================================================================
$pgTodo = New-Page 'To do' 'What PC Move cannot do for you, one step at a time. Click a step, then the button: it opens the right place. Tick a step when it is done.'
$btnTodoOpen = New-Button 'Do this step'
$lvTodo = New-ListView $true @('Step', 470, 'Why', 300)
$lblTodo = New-Status
Set-PageLayout $pgTodo $lvTodo @((New-ButtonBar @($btnTodoOpen))) $lblTodo
$BrowserExe = @{
    Chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    Edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
    Brave = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe")
    Vivaldi = @("$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe", "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe")
}
$BrowserImport = @{ Chrome = 'chrome://settings/importData'; Edge = 'edge://settings/profiles/importBrowsingData'; Brave = 'brave://settings/importData'; Vivaldi = 'vivaldi://settings/import' }
function Get-TodoDone { if (Test-Path $TodoFile) { try { @(Get-Content $TodoFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch { @() } } }   # (5.1 hands a JSON array back as one item)
function Get-TodoItems {
    if (-not $script:Bundle) { return }
    $m = $script:Bundle.M
    $doneKeys = @{}
    foreach ($k in @(Get-TodoDone)) { $doneKeys["$k"] = $true }
    $items = @()
    foreach ($b in @($m.Bookmarks)) {
        $items += @{ Id = "bm|$($b.Browser)|$($b.Profile)"; Text = "Import your $($b.Browser) bookmarks ($($b.Profile))"; Why = "In $($b.Browser): import, choose ""Bookmarks HTML file"" and pick the file in Documents > Bookmarks from the old PC."; Do = @{ Type = 'Bookmarks'; Browser = $b.Browser } }
    }
    foreach ($c in @($m.Chromium)) {
        $items += @{ Id = "signin|$c"; Text = "Sign in to $c"; Why = 'Saved passwords and open tabs come back when you sign in (they cannot be copied).'; Do = @{ Type = 'Browser'; Browser = $c } }
    }
    if ($m.Firefox) { $items += @{ Id = 'firefox'; Text = 'Sign in to Firefox'; Why = 'Firefox bookmarks and passwords come back through your Firefox account.'; Do = @{ Type = 'Url'; Url = 'https://www.mozilla.org/firefox/sync/' } } }
    if (@($m.OneDrive).Count) { $items += @{ Id = 'onedrive'; Text = 'Sign in to OneDrive'; Why = "$(@($m.OneDrive) -join ', ') were in OneDrive on the old PC - they come back when you sign in."; Do = @{ Type = 'Run'; Exe = 'OneDrive' } } }
    foreach ($w in @($m.WiFi | Where-Object { -not $_.HasKey -and -not $_.Open })) { $items += @{ Id = "wifi|$($w.Name)"; Text = "Connect to Wi-Fi ""$($w.Name)"""; Why = 'Its password was not packed up - Windows asks for it once.'; Do = @{ Type = 'Url'; Url = 'ms-availablenetworks:' } } }
    if ($m.Steam) { $items += @{ Id = 'steam'; Text = 'Sign in to Steam and install your games'; Why = 'Your games are in your Steam library; Steam downloads them again.'; Do = @{ Type = 'Url'; Url = 'https://store.steampowered.com/about/' } } }
    foreach ($p in @($m.Manual)) {
        if ($p -eq 'Microsoft 365 (Office)') { $items += @{ Id = 'office'; Text = 'Install Microsoft 365 (Office)'; Why = 'Sign in at microsoft365.com with the same account, then click Install apps.'; Do = @{ Type = 'Url'; Url = 'https://www.microsoft365.com/' } }; continue }
        $items += @{ Id = "app|$p"; Text = "Install $p"; Why = 'winget does not know this program - get it from its maker''s website.'; Do = @{ Type = 'Search'; Q = $p } }
    }
    $items += @{ Id = 'default'; Text = 'Choose your default browser and apps'; Why = 'Windows only lets you do this yourself.'; Do = @{ Type = 'Url'; Url = 'ms-settings:defaultapps' } }
    $items += @{ Id = 'printers'; Text = 'Add your printer'; Why = 'Printers usually appear by themselves on the same network; otherwise add it here.'; Do = @{ Type = 'Url'; Url = 'ms-settings:printers' } }
    $items += @{ Id = 'update'; Text = 'Run Windows Update'; Why = 'A new PC often has drivers and updates waiting.'; Do = @{ Type = 'Url'; Url = 'ms-settings:windowsupdate' } }
    $items += @{ Id = 'cleanup'; Text = 'Delete the move folder when everything works'; Why = 'It holds a copy of your files and your Wi-Fi passwords.'; Do = @{ Type = 'Folder' } }
    foreach ($i in $items) { $i.Done = [bool]$doneKeys["$($m.Created)|$($i.Id)"]; $i.Key = "$($m.Created)|$($i.Id)" }
    $items
}
function Update-Todo {
    $script:TodoLoading = $true
    $lvTodo.BeginUpdate(); $lvTodo.Items.Clear()
    $items = @(Get-TodoItems)
    foreach ($i in $items) { $it = Add-Row $lvTodo @($i.Text, $i.Why) $i $i.Done; $it.ToolTipText = T $i.Why; if ($i.Done) { $it.ForeColor = $Theme.Muted } }
    $lvTodo.EndUpdate()
    $script:TodoLoading = $false
    $left = @($items | Where-Object { -not $_.Done }).Count
    $lblTodo.Text = if (-not $script:Bundle) { 'Open a move folder on the Unpack page first.' } elseif ($left) { "$left step(s) left." } else { 'All done - enjoy your new PC.' }
    Set-NavBadge 'To do' $left
}
$lvTodo.Add_ItemChecked({
    if ($script:TodoLoading) { return }
    $done = @($lvTodo.Items | Where-Object Checked | ForEach-Object { $_.Tag.Key })
    $old = @(Get-TodoDone)
    $mine = @($lvTodo.Items | ForEach-Object { $_.Tag.Key })
    @(@($old | Where-Object { $_ -notin $mine }) + $done) | ConvertTo-Json | Set-Content $TodoFile -Encoding UTF8
    $_.Item.ForeColor = if ($_.Item.Checked) { $Theme.Muted } else { $Theme.Text }
    $left = @($lvTodo.Items | Where-Object { -not $_.Checked }).Count
    $lblTodo.Text = if ($left) { "$left step(s) left." } else { 'All done - enjoy your new PC.' }
    Set-NavBadge 'To do' $left
})
function Invoke-TodoStep($Item) {
    $d = $Item.Tag.Do
    switch ($d.Type) {
        'Bookmarks' {
            $exe = @($BrowserExe[$d.Browser] | Where-Object { Test-Path -LiteralPath $_ })[0]
            if ($exe) { Start-Process $exe $BrowserImport[$d.Browser] }
            else { Show-Msg "$($d.Browser) is not installed on this PC yet. Install it first (it may be in the list on the Unpack page), then try this step again." | Out-Null }
            $bm = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Bookmarks from the old PC'
            if (Test-Path -LiteralPath $bm) { Start-Process explorer.exe "`"$bm`"" }
        }
        'Browser' {
            $exe = @($BrowserExe[$d.Browser] | Where-Object { Test-Path -LiteralPath $_ })[0]
            if ($exe) { Start-Process $exe } else { Show-Msg "$($d.Browser) is not installed on this PC yet." | Out-Null }
        }
        'Run' { try { Start-Process $d.Exe } catch { Start-Process 'ms-settings:' } }
        'Url' { Start-Process $d.Url }
        'Search' { Start-Process "https://www.bing.com/search?q=$([uri]::EscapeDataString("$($d.Q) download"))" }
        'Folder' { if ($script:Bundle) { Start-Process explorer.exe "/select,`"$($script:Bundle.Dir)`"" } }
    }
}
$btnTodoOpen.Add_Click({ $it = @($lvTodo.SelectedItems)[0]; if ($it) { Invoke-TodoStep $it } else { Show-Msg 'Click a step in the list first.' | Out-Null } })
$lvTodo.Add_DoubleClick({ $it = @($lvTodo.SelectedItems)[0]; if ($it) { Invoke-TodoStep $it } })

# ===========================================================================
# 5. Settings
# ===========================================================================
$pgSet = New-Page 'Settings' 'How PC Move looks and behaves. Changes are saved straight away.'
$setFlow = New-Object Windows.Forms.FlowLayoutPanel
$setFlow.Dock = 'Fill'; $setFlow.FlowDirection = 'TopDown'; $setFlow.WrapContents = $false; $setFlow.AutoScroll = $true
Set-PageLayout $pgSet $setFlow @()
function Add-SetSection([string]$Title, [string]$Hint) {
    $t = New-Object Windows.Forms.Label
    $t.Text = $Title; $t.Font = $FontBold; $t.AutoSize = $true; $t.Margin = New-Object Windows.Forms.Padding(0, 16, 0, 2)
    $setFlow.Controls.Add($t)
    if ($Hint) {
        $h = New-Object Windows.Forms.Label
        $h.Text = $Hint; $h.ForeColor = $Theme.Dim; $h.AutoSize = $true; $h.MaximumSize = New-Object Drawing.Size((Px 720), 0)
        $h.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 4)
        $setFlow.Controls.Add($h)
    }
}
function Add-SetRow([object[]]$Controls) {
    $row = New-Object Windows.Forms.FlowLayoutPanel
    $row.AutoSize = $true; $row.WrapContents = $false; $row.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 2)
    foreach ($c in $Controls) { $row.Controls.Add($c) }
    $setFlow.Controls.Add($row)
}
function New-Choice([string[]]$Labels, [string[]]$Values, [string]$Current) {
    $c = New-Object Windows.Forms.ComboBox
    $c.DropDownStyle = 'DropDownList'; $c.Width = 270; $c.FlatStyle = 'Flat'; $c.BackColor = $Theme.Input; $c.ForeColor = $Theme.Text
    $c.Margin = New-Object Windows.Forms.Padding(0, 4, 10, 0)
    foreach ($l in $Labels) { [void]$c.Items.Add((T $l)) }
    $c.SelectedIndex = [Math]::Max(0, [array]::IndexOf($Values, $Current))
    $c.Tag = $Values
    $c.Add_HandleCreated({ Set-DarkChrome $this 'DarkMode_CFD' })
    $c
}
function New-Check([string]$Text, [bool]$Checked) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $Text; $c.Checked = $Checked; $c.AutoSize = $true; $c.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    $c
}
function Restart-App {
    if ($RunningAsExe) { Start-Process $StartExe } else { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" }
    $form.Close()
}

Add-SetSection 'Language' 'Takes effect when PC Move restarts.'
$cmbLang = New-Choice @('Automatic (Windows language)', 'English', 'Nederlands', 'Deutsch', 'Français', 'Español', 'Italiano', 'Polski') @('auto', 'en', 'nl', 'de', 'fr', 'es', 'it', 'pl') $Settings.Language
$btnLangRestart = New-Button 'Restart now'
Add-SetRow @($cmbLang, $btnLangRestart)
$cmbLang.Add_SelectedIndexChanged({ $Settings.Language = $this.Tag[$this.SelectedIndex]; Save-Settings })
$btnLangRestart.Add_Click({ Restart-App })

Add-SetSection 'Theme' 'Light, dark, or the same as Windows. Takes effect when PC Move restarts.'
$cmbTheme = New-Choice @('Same as Windows', 'Light', 'Dark') @('system', 'light', 'dark') $Settings.Theme
$btnThemeRestart = New-Button 'Restart now'
Add-SetRow @($cmbTheme, $btnThemeRestart)
$cmbTheme.Add_SelectedIndexChanged({ $Settings.Theme = $this.Tag[$this.SelectedIndex]; Save-Settings })
$btnThemeRestart.Add_Click({ Restart-App })

Add-SetSection 'Undo' 'Puts back the Windows settings and desktop background that PC Move changed on this PC. Programs, files and Wi-Fi networks stay: remove those the usual way if you don''t want them.'
$btnUndo = New-Button 'Undo settings changes'
Add-SetRow @($btnUndo)
function Get-UndoList { if (Test-Path $UndoFile) { try { @(Get-Content $UndoFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch { @() } } else { @() } }
function Save-UndoList($List) { if (@($List).Count) { ConvertTo-Json @($List) -Depth 4 | Set-Content $UndoFile -Encoding UTF8 } else { Remove-Item $UndoFile -ErrorAction SilentlyContinue } }
function Update-UndoButton { $n = @(Get-UndoList).Count; $btnUndo.Enabled = $n -gt 0; $btnUndo.Text = if ($n) { "Undo settings changes ($n)" } else { 'Undo settings changes' } }
$btnUndo.Add_Click({
    $list = @(Get-UndoList)
    if (-not $list) { return }
    if ((Show-Msg "Put back $($list.Count) setting(s) the way they were before PC Move changed them?`n`n$(($list | ForEach-Object { " - $($_.Name)" } | Select-Object -Unique) -join "`n")" 'YesNo' 'Question') -ne 'Yes') { return }
    [array]::Reverse($list)   # newest first, so a setting changed twice ends at its first value
    foreach ($u in $list) {
        try {
            if ($u.PSObject.Properties['Wallpaper']) { if ($u.Wallpaper) { [void][PcMove.Native]::SystemParametersInfo(20, 0, $u.Wallpaper, 3) } }
            else {
                Set-RegValue $u.P $u.N $u.Old $u.T
                if ($u.N -eq 'MouseSensitivity' -and $u.Old) { [void][PcMove.Native]::SystemParametersInfoPtr(0x71, 0, [IntPtr][int]$u.Old, 3) }
                if ($u.N -eq 'DoubleClickSpeed' -and $u.Old) { [void][PcMove.Native]::SystemParametersInfoPtr(0x20, [int]$u.Old, [IntPtr]::Zero, 3) }
            }
            Write-Log "Undid: $($u.Name)"
        } catch { Write-AppError 'Undo' $_ }
    }
    $res = [IntPtr]::Zero
    foreach ($area in 'ImmersiveColorSet', 'Policy', 'TraySettings') { [void][PcMove.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, $area, 2, 3000, [ref]$res) }
    Save-UndoList @(); Update-UndoButton
    if ($script:Bundle -and $script:Have) { Show-Unpack }
    Show-Msg 'Done. Some Explorer and taskbar settings show after you sign out and back in.' | Out-Null
})
Update-UndoButton

Add-SetSection 'Updates' $(if ($FromStore) { 'PC Move came from the Microsoft Store, which keeps it up to date.' } else { "You have version $AppVersion. New versions come from github.com/$UpdateRepo and are checked against GitHub's checksum before they are installed." })
$chkUpd = New-Check 'Check for updates when PC Move starts' ([bool]$Settings.CheckUpdates)
$chkUpd.Add_CheckedChanged({ $Settings.CheckUpdates = $this.Checked; Save-Settings })
$btnUpdate = New-Button 'Check for updates now'
Add-SetRow @($chkUpd); Add-SetRow @($btnUpdate)

Add-SetSection 'Install' $(if ($FromStore) { 'PC Move came from the Microsoft Store: it is in the Start menu, and you can uninstall it in Settings > Apps.' } else { 'PC Move runs straight from the file - installing is not needed. Install it if you want it in the Start menu and in Settings > Apps.' })
$btnInstall = New-Button 'Install on this PC'; $btnUninstall = New-Button 'Uninstall'
Add-SetRow @($btnInstall, $btnUninstall)
$btnInstall.Enabled = $RunningAsExe -and -not $IsInstalled -and -not $FromWinget -and -not $FromStore
$btnUninstall.Enabled = $IsInstalled
$btnInstall.Add_Click({ Install-App -Launch })
$btnUninstall.Add_Click({ Uninstall-App })

Add-SetSection 'Files' "PC Move keeps a log of what it did and its settings in $DataDir."
$btnLog = New-Button 'Open the log'; $btnDataDir = New-Button 'Open the folder'
Add-SetRow @($btnLog, $btnDataDir)
$btnLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe "`"$LogFile`"" } else { Show-Msg 'Nothing has been logged yet.' | Out-Null } })
$btnDataDir.Add_Click({ Start-Process explorer.exe "`"$DataDir`"" })

# --- Report a problem / suggest an idea: a GitHub issue filled in with the version, Windows and recent errors ---
function Get-ProblemInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = "$($cv.CurrentBuild).$($cv.UBR)"
    $prod = if ([int]$cv.CurrentBuild -ge 22000) { "$($cv.ProductName)" -replace 'Windows 10', 'Windows 11' } else { "$($cv.ProductName)" }
    $how = if ($FromStore) { 'Microsoft Store' } elseif ($FromWinget) { 'winget' } elseif ($IsInstalled) { 'installed' } elseif ($RunningAsExe) { 'exe, not installed' } else { 'script' }
    $clean = { param($t) $t = "$t"; foreach ($p in @($env:USERPROFILE, $env:COMPUTERNAME, $env:USERNAME) | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending) { $t = $t -ireplace [regex]::Escape($p), '<hidden>' }; $t }
    [pscustomobject]@{
        Version = "$AppVersion ($how, $(if ($IsAdmin) { 'administrator' } else { 'normal user' }), language $Lang)"
        Windows = "$prod $($cv.DisplayVersion) (build $build)"
        Errors  = (@(Get-AppErrors 14) | Select-Object -Last 15 | ForEach-Object { & $clean $_ }) -join "`n"
    }
}
function Open-ProblemReport([string]$Kind = 'bug') {
    $i = Get-ProblemInfo
    if ($Kind -eq 'bug') {
        $preview = "This opens GitHub with a new problem report, filled in with:`n`n  Version: $($i.Version)`n  Windows: $($i.Windows)`n  Recent errors: $(if ($i.Errors) { "$(@($i.Errors -split "`n").Count) line(s) (your name, folders and PC name are blanked out)" } else { 'none' })`n`nYou can read and change everything there before you press Submit. You need a free GitHub account."
        if ((Show-Msg $preview 'OKCancel' 'Information') -ne 'OK') { return }
        $q = "template=bug.yml&version=$([uri]::EscapeDataString($i.Version))&windows=$([uri]::EscapeDataString($i.Windows))"
        $err = $i.Errors; while ($err -and ([uri]::EscapeDataString($err)).Length -gt 5500) { $err = ($err -split "`n" | Select-Object -Skip 1) -join "`n" }
        if ($err) { $q += "&errors=$([uri]::EscapeDataString($err))" }
    } else { $q = "template=idea.yml&version=$([uri]::EscapeDataString($i.Version))" }
    Start-Process "https://github.com/$UpdateRepo/issues/new?$q"
}
Add-SetSection 'Help and feedback' 'Something not working, or an idea? It opens a report on GitHub with the version, Windows and recent errors already filled in (your name, folders and PC name are blanked out) - you see everything before you send it.'
$btnBug = New-Button 'Report a problem...'; $btnIdea = New-Button 'Suggest an idea...'
Add-SetRow @($btnBug, $btnIdea)
$btnBug.Add_Click({ Open-ProblemReport 'bug' })
$btnIdea.Add_Click({ Open-ProblemReport 'idea' })

Add-SetSection 'About' "PC Move $AppVersion - free and open source (MIT licence). Privacy: everything stays on your own PCs and drive. The only internet use is the update check (GitHub) and winget, which downloads the programs you move."
$lnkRepo = New-Object Windows.Forms.LinkLabel
$lnkRepo.Text = "github.com/$UpdateRepo"; $lnkRepo.AutoSize = $true; $lnkRepo.LinkColor = $Theme.AccentText; $lnkRepo.ActiveLinkColor = $Theme.AccentText
$lnkRepo.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 12)
$lnkRepo.Add_LinkClicked({ Start-Process "https://github.com/$UpdateRepo" })
$setFlow.Controls.Add($lnkRepo)

# --- Install / uninstall (per user: no administrator, no installer program) ---
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCMove'
$StartMenuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'PC Move.lnk'
function Get-ShortcutTarget([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $sh = New-Object -ComObject WScript.Shell
    try { $sc = $sh.CreateShortcut($Path); $t = $sc.TargetPath; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc); $t }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
}
function New-Shortcut([string]$Path, [string]$Target) {
    $sh = New-Object -ComObject WScript.Shell
    try {
        $sc = $sh.CreateShortcut($Path)
        $sc.TargetPath = $Target; $sc.WorkingDirectory = Split-Path $Target; $sc.IconLocation = "$Target,0"
        $sc.Description = 'Move your programs, files and settings to a new PC'
        $sc.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sc)
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
}
function Install-App([switch]$Launch) {
    if (-not $RunningAsExe) { Show-Msg 'Install from PC-Move.exe, not from the script.' | Out-Null; return }
    try {
        New-Item -ItemType Directory -Force $InstallDir | Out-Null
        if ($SelfExe -ne $InstalledExe) { Copy-Item -LiteralPath $SelfExe -Destination $InstalledExe -Force -ErrorAction Stop }
        New-Shortcut $StartMenuLink $InstalledExe
        New-Item -Path $UninstallKey -Force | Out-Null
        $vals = [ordered]@{ DisplayName = 'PC Move'; DisplayVersion = $AppVersion; Publisher = 'PC Move (open source)'; DisplayIcon = "$InstalledExe,0"
                            InstallLocation = $InstallDir; UninstallString = "`"$InstalledExe`" /uninstall"; URLInfoAbout = "https://github.com/$UpdateRepo"
                            HelpLink = "https://github.com/$UpdateRepo/issues" }
        foreach ($k in $vals.Keys) { Set-ItemProperty -Path $UninstallKey -Name $k -Value $vals[$k] }
        foreach ($k in 'NoModify', 'NoRepair') { Set-ItemProperty -Path $UninstallKey -Name $k -Value 1 -Type DWord }
        Set-ItemProperty -Path $UninstallKey -Name EstimatedSize -Value ([int]((Get-Item -LiteralPath $InstalledExe).Length / 1KB)) -Type DWord
        Write-Log "Installed PC Move $AppVersion in $InstallDir"
    } catch { Show-Msg "Installing failed: $($_.Exception.Message)" 'OK' 'Warning' | Out-Null; return }
    if ($Launch -and $SelfExe -ne $InstalledExe) {
        Show-Msg 'PC Move is installed. It is in the Start menu, and you can uninstall it in Settings > Apps.' | Out-Null
        Start-Process $InstalledExe
        $form.Close()
    }
}
function Uninstall-App {
    if ((Show-Msg 'Remove PC Move from this PC?' 'YesNo' 'Question') -ne 'Yes') { return }
    $wipe = (Show-Msg 'Also delete its settings and log?' 'YesNo' 'Question') -eq 'Yes'
    try { if ((Get-ShortcutTarget $StartMenuLink) -eq $InstalledExe) { Remove-Item $StartMenuLink -Force } } catch { }
    Remove-Item -Path $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    if ($wipe) { Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue }
    $self = $SelfExe -eq $InstalledExe
    if (-not $self) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    Show-Msg 'PC Move has been removed.' | Out-Null
    if ($self) {
        # A running program can't delete itself: a hidden helper waits until this process has ended, then removes the folder.
        $dir = $InstallDir -replace "'", "''"
        $cmd = "Wait-Process -Id $PID -Timeout 60 -ErrorAction SilentlyContinue; " +
               "for (`$i = 0; `$i -lt 20 -and (Test-Path -LiteralPath '$dir'); `$i++) { Start-Sleep 1; Remove-Item -LiteralPath '$dir' -Recurse -Force -ErrorAction SilentlyContinue }"
        Start-Process powershell.exe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cmd`"" -WindowStyle Hidden -WorkingDirectory $env:TEMP
    }
    $form.Close()
}

# --- Updates: the latest GitHub release, checked against GitHub's SHA-256 before it replaces this exe ---
$UpdateCheckWork = {
    param($repo)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'PC-Move' } -TimeoutSec 15
        $asset = @($r.assets | Where-Object name -eq 'PC-Move.exe')[0]
        [pscustomobject]@{ Version = ($r.tag_name -replace '^v', ''); Notes = [string]$r.body; Url = $asset.browser_download_url
                           Digest = [string]$asset.digest; Page = $r.html_url; Error = $null }
    } catch { [pscustomobject]@{ Error = $_.Exception.Message } }
}
$UpdateDownloadWork = {
    param($info)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $file = Join-Path $env:TEMP "PC-Move-$($info.Version).exe"
    try {
        Invoke-WebRequest $info.Url -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'PC-Move' } -TimeoutSec 120
        if ($info.Digest -match '^sha256:([0-9a-f]{64})$') {
            if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $Matches[1]) { Remove-Item $file -Force; throw 'downloaded file is damaged (checksum mismatch)' }
        }
        [pscustomobject]@{ File = $file; Error = $null }
    } catch { [pscustomobject]@{ File = $null; Error = $_.Exception.Message } }
}
function Start-UpdateCheck([switch]$Silent) {
    if ($FromStore) { if (-not $Silent) { Show-Msg 'PC Move came from the Microsoft Store, which keeps it up to date.' | Out-Null }; return }
    $btnUpdate.Enabled = $false
    $script:UpdateSilent = [bool]$Silent
    Start-Bg $UpdateCheckWork $UpdateRepo {
        param($r)
        $btnUpdate.Enabled = $true
        $r = $r[0]
        if ($r.Error) { if (-not $script:UpdateSilent) { Show-Msg "Couldn't check for updates:`n$($r.Error)" 'OK' 'Warning' | Out-Null }; return }
        $newer = try { [version]$r.Version -gt [version]$AppVersion } catch { $false }
        if (-not $newer) { if (-not $script:UpdateSilent) { Show-Msg "You have the latest version ($AppVersion)." | Out-Null }; return }
        if ($script:Jobs | Where-Object { $_.Label -in 'Packing up', 'Unpacking' }) { return }   # never in the middle of a move
        $notes = (($r.Notes -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 8) -join "`n").Trim()
        if ($FromWinget) {
            if ((Show-Msg "PC Move $($r.Version) is available (you have $AppVersion).`n`n$notes`n`nIt was installed with winget, so winget updates it. Update now? (A window opens; start PC Move again afterwards.)" 'YesNo' 'Information') -eq 'Yes') {
                Start-Process cmd.exe '/c winget upgrade --id MichaelKloprogge.PCMove --exact --accept-source-agreements & pause'
                $form.Close()
            }
            return
        }
        if (-not $RunningAsExe -or -not $r.Url) {
            if ((Show-Msg "PC Move $($r.Version) is available (you have $AppVersion).`n`n$notes`n`nOpen the download page?" 'YesNo' 'Information') -eq 'Yes') { Start-Process $r.Page }
            return
        }
        if ((Show-Msg "PC Move $($r.Version) is available (you have $AppVersion).`n`n$notes`n`nUpdate now? The app restarts by itself." 'YesNo' 'Information') -ne 'Yes') { return }
        $btnUpdate.Enabled = $false; $btnUpdate.Text = 'Downloading...'
        $script:UpdateInfo = $r
        Start-Bg -Label 'Downloading the update' $UpdateDownloadWork $r {
            param($d)
            $d = $d[0]
            $btnUpdate.Text = 'Check for updates now'; $btnUpdate.Enabled = $true
            if ($d.Error) { Show-Msg "Update failed: $($d.Error)" 'OK' 'Warning' | Out-Null; return }
            # A running exe can be renamed but not overwritten: move it aside, put the new one in its place, restart.
            $old = [IO.Path]::ChangeExtension($SelfExe, '.old.exe')
            try {
                Remove-Item $old -Force -ErrorAction SilentlyContinue
                Move-Item -LiteralPath $SelfExe -Destination $old -ErrorAction Stop
                try { Move-Item -LiteralPath $d.File -Destination $SelfExe -ErrorAction Stop }
                catch { Move-Item -LiteralPath $old -Destination $SelfExe; throw }
            } catch {
                Show-Msg "Couldn't replace the app file ($($_.Exception.Message)). Download it yourself from:`n$($script:UpdateInfo.Page)" 'OK' 'Warning' | Out-Null
                return
            }
            Write-Log "Updated PC Move $AppVersion -> $($script:UpdateInfo.Version)"
            Start-Process $StartExe
            $form.Close()
        }
    }
}
$btnUpdate.Add_Click({ Start-UpdateCheck })
$OldExeCleanupWork = {
    param($old)
    for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath $old); $i++) { Start-Sleep 2; Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# Sidebar
# ===========================================================================
$NavPages = @('Start', 'Pack up', 'Unpack', 'To do', 'Settings')
$script:NavButtons = @{}
$script:PageLoaders = @{ 'Pack up' = { Start-Inventory } }
$script:Loaded = @{}
function Show-Page($Page) {
    $script:CurrentPage = $Page
    foreach ($p in $script:Pages) { $p.Visible = ($p -eq $Page) }
    foreach ($b in $script:NavButtons.Values) {
        $on = $b.Tag -eq $Page
        $b.BackColor = if ($on) { $Theme.AccentSoft } else { $Theme.Side }
        $b.ForeColor = if ($on) { $Theme.AccentText } else { $Theme.Text }
        $b.Font = if ($on) { $FontBold } else { $Font }
        $b.Invalidate()
    }
    $n = $Page.Name
    if (-not $script:Loaded[$n] -and $script:PageLoaders.ContainsKey($n)) { $script:Loaded[$n] = $true; & $script:PageLoaders[$n] }
}
function Set-NavBadge([string]$Name, $Count) {
    $b = $script:NavButtons[$Name]
    if ($b) { $b.Text = if ($Count) { "$(T $Name)  ($Count)" } else { T $Name } }
}
$IconFontName = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$IconFont = New-Object Drawing.Font($IconFontName, 11)
$NavIcons = @{ Start = 0xE80F; 'Pack up' = 0xE7B8; Unpack = 0xE896; 'To do' = 0xE9D5; Settings = 0xE713 }
function Draw-NavButton($B, $G) {
    $G.SmoothingMode = 'AntiAlias'
    $G.Clear($Theme.Side)
    $on = $B.BackColor.ToArgb() -eq $Theme.AccentSoft.ToArgb()
    if ($on -or $script:HotNav -eq $B) {
        $p = New-RoundRect 0.5 0.5 ($B.Width - 1.5) ($B.Height - 1.5) (Px 5)
        $br = New-Object Drawing.SolidBrush($(if ($on) { $Theme.AccentSoft } else { $Theme.Hover })); $G.FillPath($br, $p); $br.Dispose(); $p.Dispose()
    }
    if ($on) {   # the bar on the left, like Windows 11 Settings
        $h = [single]($B.Height * 0.5); $bar = New-RoundRect 1 (($B.Height - $h) / 2) (Px 3) $h (Px 2)
        $br = New-Object Drawing.SolidBrush($Theme.Accent); $G.FillPath($br, $bar); $br.Dispose(); $bar.Dispose()
    }
    $x = Px 10
    $code = $NavIcons[$B.AccessibleName]
    if ($code) {
        [Windows.Forms.TextRenderer]::DrawText($G, [string][char]$code, $IconFont, (New-Object Drawing.Rectangle($x, 0, (Px 20), $B.Height)), $(if ($on) { $Theme.AccentText } else { $Theme.Dim }), 'VerticalCenter, HorizontalCenter, NoPrefix')
        $x += Px 30
    }
    $text = $B.Text; $right = $B.Width - (Px 4)
    if ($text -match '^(.*?)\s+\((\d+)\)$') {   # a count is drawn as a small pill on the right
        $text = $Matches[1]; $count = $Matches[2]
        $pw = [Windows.Forms.TextRenderer]::MeasureText($count, $FontSmall).Width + (Px 8); $ph = Px 17
        $px = $B.Width - (Px 6) - $pw; $py = [int](($B.Height - $ph) / 2)
        $pill = New-RoundRect $px $py $pw $ph ($ph / 2)
        $br = New-Object Drawing.SolidBrush($(if ($on) { $Theme.Bg } else { $Theme.Hover })); $G.FillPath($br, $pill); $br.Dispose(); $pill.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($G, $count, $FontSmall, (New-Object Drawing.Rectangle($px, $py, $pw, $ph)), $(if ($on) { $Theme.AccentText } else { $Theme.Dim }), 'VerticalCenter, HorizontalCenter, NoPrefix')
        $right = $px - (Px 4)
    }
    [Windows.Forms.TextRenderer]::DrawText($G, $text, $B.Font, (New-Object Drawing.Rectangle($x, 0, ($right - $x), $B.Height)), $B.ForeColor, 'VerticalCenter, Left, EndEllipsis, NoPrefix')
    if ($B.Focused -and $B.ShowFocusCues) { $fp = New-RoundRect 1.5 1.5 ($B.Width - 3.5) ($B.Height - 3.5) (Px 4); $pen = New-Object Drawing.Pen($Theme.Accent); $pen.DashStyle = 'Dot'; $G.DrawPath($pen, $fp); $pen.Dispose(); $fp.Dispose() }
}
$nav = New-Object Windows.Forms.FlowLayoutPanel
$nav.Dock = 'Fill'; $nav.FlowDirection = 'TopDown'; $nav.WrapContents = $false; $nav.AutoScroll = $true
$nav.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 2)
$appName = New-Object Windows.Forms.Label
$appName.Text = 'PC Move'; $appName.Font = $FontBig; $appName.AutoSize = $true; $appName.Margin = New-Object Windows.Forms.Padding(6, 0, 0, 0)
$appVer = New-Object Windows.Forms.Label
$appVer.Text = "Version $AppVersion"; $appVer.ForeColor = $Theme.Dim; $appVer.AutoSize = $true; $appVer.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 10)
$nav.Controls.AddRange(@($appName, $appVer))
foreach ($name in $NavPages) {
    $page = $script:Pages | Where-Object Name -eq $name | Select-Object -First 1
    $b = New-Object Windows.Forms.Button
    $b.Text = $name; $b.Tag = $page; $b.Width = 170; $b.Height = 32; $b.TextAlign = 'MiddleLeft'
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $Theme.Hover
    $b.BackColor = $Theme.Side; $b.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 2); $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.AccessibleName = $name
    $b.Add_Click({ Show-Page $this.Tag })
    $b.Add_Paint({ param($sender, $e) Draw-NavButton $sender $e.Graphics })
    $b.Add_MouseEnter({ $script:HotNav = $this; $this.Invalidate() })
    $b.Add_MouseLeave({ if ($script:HotNav -eq $this) { $script:HotNav = $null }; $this.Invalidate() })
    $b.Add_GotFocus({ $this.Invalidate() }); $b.Add_LostFocus({ $this.Invalidate() })
    $script:NavButtons[$name] = $b
    $nav.Controls.Add($b)
}
$sidebar.Controls.Add($nav)
if (-not $IsAdmin) {
    $adm = New-Object Windows.Forms.Panel
    $adm.Dock = 'Bottom'; $adm.Height = 116; $adm.Padding = New-Object Windows.Forms.Padding(14, 6, 14, 10)
    $admL = New-Object Windows.Forms.Label
    $admL.Dock = 'Fill'; $admL.ForeColor = $Theme.Dim; $admL.Font = New-Object Drawing.Font('Segoe UI', 8.25)
    $admL.Text = 'As administrator, Wi-Fi passwords come along and programs install without questions.'
    $admB = New-Button 'Run as administrator'
    $admB.AutoSize = $false; $admB.Dock = 'Bottom'; $admB.Height = 32
    $admB.Add_Click({
        if ($script:Jobs | Where-Object { $_.Label -in 'Packing up', 'Unpacking' }) { Show-Msg 'Wait until PC Move is finished, or press Cancel first.' | Out-Null; return }
        try {
            if ($RunningAsExe) { Start-Process $StartExe -Verb RunAs }
            else { Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" }
            $form.Close()
        } catch { }   # the person said no to the Windows prompt
    })
    $adm.Controls.AddRange(@($admL, $admB))
    $sidebar.Controls.Add($adm)
}
foreach ($b in @($btnPack, $btnUnpack, $btnTodoOpen)) { Set-Primary $b }

# ---------------------------------------------------------------------------
# Activity bar: what is running in the background, its progress, and Cancel
# ---------------------------------------------------------------------------
$activity = New-Object Windows.Forms.Panel
$activity.Dock = 'Bottom'; $activity.Height = 42; $activity.BackColor = $Theme.Soft; $activity.Visible = $false
$activity.Padding = New-Object Windows.Forms.Padding(26, 7, 26, 7)
$actText = New-Object Windows.Forms.Label
$actText.Dock = 'Fill'; $actText.TextAlign = 'MiddleLeft'; $actText.AutoEllipsis = $true
$actBar = New-Object Windows.Forms.PictureBox
$actBar.Dock = 'Right'; $actBar.Width = 220; $actBar.BackColor = $Theme.Soft
$script:ActProg = @{ Max = 0; Value = 0; Pos = 0.0 }
$actBar.Add_Paint({ param($sender, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $h = [single](Px 6); $y = ($sender.Height - $h) / 2; $w = [single]($sender.Width - 2)
    $track = New-RoundRect 1 $y $w $h ($h / 2); $br = New-Object Drawing.SolidBrush($Theme.Border); $g.FillPath($br, $track); $br.Dispose(); $track.Dispose()
    $p = $script:ActProg
    if ($p.Max -gt 0) { $x0 = 1; $fw = [single]([Math]::Max([double]$h, $w * [Math]::Min([double]1, [double]$p.Value / [double]$p.Max))) }
    else { $fw = [single]($w * 0.3); $x0 = 1 + ($w - $fw) * (0.5 - 0.5 * [Math]::Cos($p.Pos)) }
    $fill = New-RoundRect $x0 $y $fw $h ($h / 2); $br = New-Object Drawing.SolidBrush($Theme.Accent); $g.FillPath($br, $fill); $br.Dispose(); $fill.Dispose()
})
$actAnim = New-Object Windows.Forms.Timer; $actAnim.Interval = 40
$actAnim.Add_Tick({ if ($activity.Visible -and $script:ActProg.Max -le 0) { $script:ActProg.Pos += 0.08; $actBar.Invalidate() } })
$actAnim.Start()
$actGap = New-Object Windows.Forms.Panel; $actGap.Dock = 'Right'; $actGap.Width = 10
$actCancel = New-Button 'Cancel'
$actCancel.AutoSize = $false; $actCancel.Dock = 'Right'; $actCancel.Width = 96
$activity.Controls.Add($actText); $activity.Controls.Add($actBar); $activity.Controls.Add($actGap); $activity.Controls.Add($actCancel)
$content.Controls.Add($activity); $activity.SendToBack()
$actCancel.Add_Click({ if ($this.Tag) { $this.Tag.State.Cancel = $true; Update-ActivityBar } })
function Update-ActivityBar {
    $running = @($script:Jobs | Where-Object { $_.Label } | Sort-Object { -[int]$_.Cancellable })
    if (-not $running) { if ($activity.Visible) { $activity.Visible = $false }; return }
    $j = $running[0]
    $t = (T $j.Label) + $(if ($j.State.Text) { ": $(T $j.State.Text)" })
    if ($actText.Text -ne $t) { $actText.Text = $t }
    $script:ActProg.Max = [Math]::Max(0, $j.State.Max); $script:ActProg.Value = [Math]::Max(0, $j.State.Value); $actBar.Invalidate()
    $actCancel.Visible = $j.Cancellable; $actCancel.Tag = $j
    $actCancel.Enabled = -not $j.State.Cancel
    $actCancel.Text = if ($j.State.Cancel) { 'Stopping...' } else { 'Cancel' }
    if (-not $activity.Visible) { $activity.Visible = $true }
}
# Closing in the middle of a move: ask first, then stop it cleanly.
$form.Add_FormClosing({
    $busy = @($script:Jobs | Where-Object { $_.Label -in 'Packing up', 'Unpacking' })
    if ($busy -and -not $script:ForceClose) {
        if ((Show-Msg 'PC Move is still busy. Stop and close anyway? What is done so far stays done.' 'YesNo' 'Warning') -ne 'Yes') { $_.Cancel = $true; return }
        foreach ($j in $busy) { $j.State.Cancel = $true }
    }
})

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
function Write-Cli([string]$Text) { try { [Console]::Out.WriteLine((T $Text)) } catch { } }
if ($Cli.Help -or $Cli.Install -or $Cli.Uninstall) {
    if ($RunningAsExe -and [PcMove.Native]::AttachConsole(-1)) { $w = New-Object IO.StreamWriter([Console]::OpenStandardOutput()); $w.AutoFlush = $true; [Console]::SetOut($w) }
    if ($Cli.Install) { Install-App; Write-Cli "PC Move installed in $InstallDir" }
    elseif ($Cli.Uninstall) { Uninstall-App }
    else { Write-Cli "PC Move $AppVersion`n`n  PC-Move.exe                   open PC Move`n  PC-Move.exe /install | /uninstall  install or remove for this user" }
    $JobTimer.Stop()
    return
}
Enable-Translation $form
foreach ($n in $NavPages) { Set-NavBadge $n 0 }
Show-Page $pgStart
Update-Found
$form.Add_Shown({
    if ($Settings.CheckUpdates) { Start-UpdateCheck -Silent }
    if ($IsInstalled) { try { Set-ItemProperty -Path $UninstallKey -Name DisplayVersion -Value $AppVersion -ErrorAction Stop } catch { } }
    $oldExe = [IO.Path]::ChangeExtension($SelfExe, '.old.exe')
    if ($RunningAsExe -and (Test-Path -LiteralPath $oldExe)) { Start-Bg $OldExeCleanupWork $oldExe { } }
    # Started from inside a move folder (on the new PC, from the USB drive): go straight to unpacking.
    if ($RunningAsExe -and (Read-Bundle (Split-Path -Parent $SelfExe)) -and $env:COMPUTERNAME -ne (Read-Bundle (Split-Path -Parent $SelfExe)).From.Pc) {
        Show-Page $pgUnpack; Open-Bundle (Split-Path -Parent $SelfExe)
    }
})
# Grow every control by the screen scaling (fonts already scale on their own; list columns and row heights were sized with Px).
if ($DpiScale -ne 1) { $form.Scale((New-Object Drawing.SizeF($DpiScale, $DpiScale))) }
$work = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size([Math]::Min($form.Width, $work.Width - 40), [Math]::Min($form.Height, $work.Height - 40))
$form.MinimumSize = New-Object Drawing.Size((Px 900), (Px 560))
[void]$form.ShowDialog()
$JobTimer.Stop()
