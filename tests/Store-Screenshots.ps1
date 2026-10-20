# Pictures for the Microsoft Store listing: opens PC Move hidden, fills every page with made-up data (Anna's old
# laptop: ordinary programs, folders, Wi-Fi networks, a move folder) and saves start, pack-up, unpack and to-do.
# Nothing about this PC is shown, and nothing outside a temporary folder is changed.
# Usage: powershell -STA -File .\tests\Store-Screenshots.ps1 [-Language nl] [-Theme dark] [-Out folder]
param([string]$Language = 'en', [string]$Theme = 'light', [string]$Out)
if (-not $Out) { $Out = Join-Path $PSScriptRoot "..\store\screenshots\$Language" }
New-Item -ItemType Directory -Force $Out | Out-Null
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\pc-move.ps1'))
$harness = @'
function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') { if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' } }
function Start-Process { }
function Snap([string]$Name) {
    for ($i = 0; $i -lt 10; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path '__OUT__' "$Name.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$root = Join-Path $env:TEMP "pcmove-store-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$TodoFile = Join-Path $root 'todo.json'

# The demo user's folders and Windows settings, first on the old PC, then on the new one.
function Get-PersonalFolders {
    foreach ($k in 'Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads') { [pscustomobject]@{ Key = $k; Name = $k; Path = "C:\Users\Anna\$k"; OneDrive = $false } }
}
$script:DemoReg = @{ AppsUseLightTheme = 0; SystemUsesLightTheme = 0; TaskbarAl = 0; SearchboxTaskbarMode = 1; HideFileExt = 0; Hidden = 2; LaunchTo = 1; MouseSensitivity = '14'; DoubleClickSpeed = '500' }
function Get-RegValue([string]$Path, [string]$Name) { $script:DemoReg[$Name] }
$wallpaper = Join-Path $root 'beach.jpg'
[IO.File]::WriteAllBytes($wallpaper, (New-Object byte[] 2400000))
function Get-WallpaperFile { $wallpaper }
$script:Loaded['Pack up'] = $true   # never look at this PC's programs
$lblFound.Text = ''; $btnFound.Visible = $false

$form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-3000, 0)   # off screen
$form.Show()
$form.MinimumSize = New-Object Drawing.Size(0, 0); $form.Size = New-Object Drawing.Size(1440, 900)
Snap 'start'

# --- Pack up, on Anna's old laptop ---
$apps = @(
    @{ Name = '7-Zip'; Id = '7zip.7zip' }, @{ Name = 'Adobe Acrobat Reader'; Id = 'Adobe.Acrobat.Reader.64-bit' }, @{ Name = 'Google Chrome'; Id = 'Google.Chrome' }
    @{ Name = 'Mozilla Firefox'; Id = 'Mozilla.Firefox' }, @{ Name = 'Spotify'; Id = '9NCBCSZSJRSB'; Source = 'msstore' }, @{ Name = 'Steam'; Id = 'Valve.Steam' }
    @{ Name = 'VLC media player'; Id = 'VideoLAN.VLC' }, @{ Name = 'Zoom Workplace'; Id = 'Zoom.Zoom' }
    @{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)'; Id = 'Microsoft.VCRedist.2015+.x64' }
) | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Source = $(if ($_.Source) { $_.Source } else { 'winget' }) } }
$folders = @(
    @{ Key = 'Desktop'; Bytes = 312MB; Files = 46 }, @{ Key = 'Documents'; Bytes = 4.2GB; Files = 3218 }, @{ Key = 'Pictures'; Bytes = 38.6GB; Files = 12480 }
    @{ Key = 'Music'; Bytes = 6.8GB; Files = 1904 }, @{ Key = 'Videos'; Bytes = 21.3GB; Files = 214 }, @{ Key = 'Downloads'; Bytes = 2.1GB; Files = 187 }
) | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Name = $_.Key; Path = "C:\Users\Anna\$($_.Key)"; OneDrive = $false; Bytes = [double]$_.Bytes; Files = $_.Files } }
$wifi = @(
    [pscustomobject]@{ Name = 'Home WiFi'; HasKey = $true; Open = $false; Work = $false }
    [pscustomobject]@{ Name = 'Garden Cafe Guest'; HasKey = $false; Open = $true; Work = $false }
    [pscustomobject]@{ Name = 'Grandma and Grandpa'; HasKey = $true; Open = $false; Work = $false }
)
$script:Inventory = [pscustomobject]@{ Apps = $apps; Folders = $folders; WiFi = $wifi; Manual = @('Family Tree Maker 2019', 'Canon IJ Scan Utility')
    Bookmarks = @([pscustomobject]@{ Browser = 'Chrome'; Profile = 'Anna'; Count = 214; Html = '' }); Firefox = $true; Chromium = @('Chrome'); Steam = $true }
Show-Page $pgPack
Show-Inventory $script:Inventory $false
$script:PackDest = 'E:\'; Update-PackSummary
Snap 'pack-up'

# --- Unpack, on the new PC, from the move folder Anna made ---
$created = (Get-Date).AddDays(-1).Date.AddHours(14).AddMinutes(32)
$bundleDir = Join-Path $root 'bundle'
foreach ($f in $folders) { New-Item -ItemType Directory -Force (Join-Path $bundleDir "Files\$($f.Key)") | Out-Null }
Copy-Item $wallpaper (Join-Path $bundleDir 'wallpaper.jpg')
$m = [pscustomobject]@{
    Format = 'PC Move bundle'; Version = $AppVersion; Created = $created.ToString('s'); Complete = $true
    From = [pscustomobject]@{ Pc = 'ANNA-LAPTOP'; User = 'Anna'; Windows = 'Windows 10 Home 22H2' }
    Apps = @($apps | Select-Object -First 8); Manual = $script:Inventory.Manual
    Settings = @(foreach ($s in $SettingsCatalog) { [pscustomobject]@{ Key = $s.Key; Value = $script:DemoReg[$s.N] } })
    WiFi = @($wifi | ForEach-Object { [pscustomobject]@{ Name = $_.Name; HasKey = $_.HasKey; Open = $_.Open; File = "WiFi\$($_.Name).xml" } })
    Wallpaper = 'wallpaper.jpg'
    Bookmarks = @([pscustomobject]@{ Browser = 'Chrome'; Profile = 'Anna'; Count = 214; File = 'Bookmarks\Chrome - Anna.html' })
    Folders = @($folders | Where-Object Key -ne 'Downloads' | ForEach-Object { [pscustomobject]@{ Key = $_.Key; Name = $_.Name; Dir = "Files\$($_.Key)"; Bytes = $_.Bytes; Files = $_.Files } })
    OneDrive = @(); Firefox = $true; Chromium = @('Chrome'); Steam = $true
}
# A new PC: Windows' own settings, and Chrome is already installed.
$script:DemoReg = @{ AppsUseLightTheme = 1; SystemUsesLightTheme = 1; TaskbarAl = 1; SearchboxTaskbarMode = 2; HideFileExt = 1; Hidden = 2; LaunchTo = 2; MouseSensitivity = '10'; DoubleClickSpeed = '500' }
$script:Bundle = @{ Dir = $bundleDir; M = $m }
$script:Have = [pscustomobject]@{ Ids = @('Google.Chrome'); NoWinget = $false; WiFi = @() }
Show-Page $pgUnpack
$lblBundle.Text = "Move folder: E:\PC Move - ANNA-LAPTOP - $($created.ToString('yyyy-MM-dd HHmm'))`nFrom ANNA-LAPTOP (Windows 10 Home 22H2), packed up on $($created.ToString('f'))."
Show-Unpack
Snap 'unpack'

# --- To do: two steps already done ---
Update-Todo
Show-Page $pgTodo
foreach ($it in $lvTodo.Items) { if ($it.Tag.Id -in 'signin|Chrome', 'bm|Chrome|Anna') { $it.Checked = $true } }
Snap 'to-do'

$form.Close()
$JobTimer.Stop()
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
'@
# The free space on the made-up USB drive.
$free = '$free = try { (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:PackDest))).AvailableFreeSpace } catch { 0 }'
$i = $src.IndexOf($free)
if ($i -lt 0) { throw 'Update-PackSummary changed - update Store-Screenshots.ps1' }
$src = $src.Substring(0, $i) + '$free = 118.4GB' + $src.Substring($i + $free.Length)
$src = $src.Replace('[void]$form.ShowDialog()', $harness.Replace('__OUT__', (Resolve-Path $Out).Path))
$src = $src.Replace("`$Settings = [ordered]@{ Language = 'auto'; Theme = 'system'", "`$Settings = [ordered]@{ Language = '$Language'; Theme = '$Theme'")
$src = $src.Replace("if (Test-Path `$SettingsFile) {", "if (`$false) {")
$src = $src.Replace("`$form.Add_Shown({", "`$null = ({")   # no update check
$tmp = Join-Path $env:TEMP "pcmove-store-shots-$PID.ps1"
[IO.File]::WriteAllText($tmp, $src, (New-Object Text.UTF8Encoding($true)))
$env:PCMOVE_LANGDIR = Join-Path $PSScriptRoot '..\lang'
try { & $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
"Saved to $Out"
