# Loads the whole PC Move app without showing its window and runs a real move between two temporary folders:
# look at this PC, pack up a test folder, a test setting and a bookmark file, open the move folder, unpack it again.
# Nothing outside the temporary folders and HKCU:\Software\PCMoveTest is changed.
# Usage: powershell -STA -File .\tests\Test-App.ps1 [-Language nl] [-SkipInventory]   (exits 1 on failure; used by the GitHub build)
param([string]$Language = 'en', [switch]$SkipInventory, [int]$TimeoutSec = 400)
$app = Join-Path $PSScriptRoot '..\pc-move.ps1'
$src = [IO.File]::ReadAllText($app)
$harness = @'
$script:Fail = 0
trap { "FAIL  test stopped: $_ $($_.InvocationInfo.PositionMessage)"; $JobTimer.Stop(); exit 1 }
. ([scriptblock]::Create($Helpers))   # the background helpers (bookmark conversion) in this scope too
function Check([bool]$Ok, [string]$What) { if ($Ok) { "ok    $What" } else { $script:Fail++; "FAIL  $What" } }
function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') { "  [message] $($Text -replace "`r?`n", ' | ')" | Out-Host; if ($Buttons -eq 'YesNo') { 'Yes' } else { 'OK' } }
function Start-Process { param([Parameter(ValueFromRemainingArguments)]$Rest) "  [would open] $Rest" | Out-Host }
function Wait-Jobs([int]$Sec = __TIMEOUT__) { $d = (Get-Date).AddSeconds($Sec); do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } while ($script:Jobs.Count -and (Get-Date) -lt $d); Check (-not $script:Jobs.Count) "background work finished within $Sec s" }
$errBefore = if (Test-Path $ErrorLogFile) { @(Get-Content $ErrorLogFile).Count } else { 0 }

Check ([bool](Get-Command T)) 'app loaded'
Check ($script:CurrentPage -eq $pgStart) 'Start page shown'
Check (@($script:Pages).Count -eq 5) 'five pages'
Check (@(Get-PersonalFolders).Count -ge 6) 'personal folders found'

# --- 1. Look at this PC ---
if (-not $SKIP) {
    Show-Page $pgPack; Wait-Jobs
    Check ($script:Inventory -ne $null) 'inventory came back'
    Check ($lvPack.Items.Count -gt 0) "pack list has rows ($($lvPack.Items.Count))"
    "  status: $($lblPack.Text)"
    foreach ($k in 'App', 'Folder', 'WiFi', 'Setting', 'Wallpaper', 'Bookmarks') { "  $k rows: $(@($lvPack.Items | Where-Object { $_.Tag.Kind -eq $k }).Count), checked $(@($lvPack.CheckedItems | Where-Object { $_.Tag.Kind -eq $k }).Count)" }
    Check (-not @($lvPack.Items | Where-Object { $_.Tag.Kind -eq 'App' -and $_.Tag.Data.Id -match '^Microsoft\.VCRedist' -and $_.Checked })) 'runtimes are not pre-checked'
    Check (-not @($script:Inventory.WiFi | Where-Object { -not $_.Name })) 'every Wi-Fi network has a name'
    "  programs: $((@($lvPack.Items | Where-Object { $_.Tag.Kind -eq 'App' }) | ForEach-Object { "$(if ($_.Checked) { '[x]' } else { '[ ]' }) $($_.SubItems[1].Text)" }) -join '; ')"
    "  to do on the new PC: $($script:Inventory.Manual -join '; ')"
    Check (-not (Get-ChildItem $env:TEMP -Directory -Filter 'pcmove-wifi-*' -ErrorAction SilentlyContinue)) 'no Wi-Fi password files left in TEMP'
}

# --- 2. Pack up a test folder, setting and bookmarks ---
$root = Join-Path $env:TEMP "pcmove-test-$PID"
$from = Join-Path $root 'old\Documents'; $dest = Join-Path $root 'usb'; $to = Join-Path $root 'new\Documents'
New-Item -ItemType Directory -Force (Join-Path $from 'Sub folder'), $dest, $to | Out-Null
Set-Content (Join-Path $from 'letter.txt') 'from the old PC'
Set-Content (Join-Path $from 'Sub folder\photo.jpg') ('x' * 5000)
Set-Content (Join-Path $to 'letter.txt') 'already on the new PC'   # must survive the unpack
$testKey = 'HKCU:\Software\PCMoveTest'
Set-RegValue $testKey 'Choice' 7
$SettingsCatalog = @($SettingsCatalog) + @(@{ Key = 'Test'; Name = 'Test setting'; P = $testKey; N = 'Choice'; Values = @{ '7' = 'seven'; '3' = 'three' } })
$bm = ConvertTo-BookmarkHtml ([pscustomobject]@{ roots = [pscustomobject]@{ bookmark_bar = [pscustomobject]@{ name = 'Bar'; children = @(
    [pscustomobject]@{ type = 'url'; name = 'Tom & Jerry <3'; url = 'https://example.com/?a=1&b=2' }
    [pscustomobject]@{ type = 'folder'; name = 'News'; children = @([pscustomobject]@{ type = 'url'; name = 'BBC'; url = 'https://bbc.co.uk' }) }) } } })
Check ($bm.Count -eq 2) 'bookmarks converted (2 links)'
Check ($bm.Html -match 'Tom &amp; Jerry &lt;3' -and $bm.Html -match 'a=1&amp;b=2' -and $bm.Html -match 'PERSONAL_TOOLBAR_FOLDER') 'bookmark file is valid HTML'

$script:Inventory = [pscustomobject]@{ Manual = @('Some Old Program 2.1'); Folders = @(); Firefox = $true; Chromium = @('Chrome') }
$lvPack.Items.Clear()
$folder = [pscustomobject]@{ Key = 'Documents'; Name = 'Documents'; Path = $from; OneDrive = $false; Bytes = 5100; Files = 2 }
[void](Add-Row $lvPack @('Folder', 'Documents', '', '') @{ Kind = 'Folder'; Bytes = 5100; Data = $folder } $true)
[void](Add-Row $lvPack @('Setting', 'Test setting', '', '') @{ Kind = 'Setting'; Data = @{ Key = 'Test'; Value = 7 } } $true)
[void](Add-Row $lvPack @('Bookmarks', 'Chrome', '', '') @{ Kind = 'Bookmarks'; Data = [pscustomobject]@{ Browser = 'Chrome'; Profile = 'Person 1'; Count = 2; Html = $bm.Html } } $true)
[void](Add-Row $lvPack @('Wi-Fi', 'Home', '', '') @{ Kind = 'WiFi'; Data = [pscustomobject]@{ Name = 'Home'; Xml = '<WLANProfile><name>Home</name></WLANProfile>'; HasKey = $true; Open = $false } } $true)
$script:PackDest = $dest
Update-PackSummary
Start-Pack; Wait-Jobs
$bundle = @(Get-ChildItem $dest -Directory -Filter 'PC Move - *')[0]
Check ([bool]$bundle) 'move folder made'
$m = Read-Bundle $bundle.FullName
Check ($m -and $m.Complete) 'pc-move.json written and complete'
Check (Test-Path (Join-Path $bundle.FullName 'Files\Documents\Sub folder\photo.jpg')) 'files copied, with subfolders'
Check (@($m.Folders)[0].Files -eq 2) "file count recorded ($(@($m.Folders)[0].Files))"
Check (@($m.WiFi).Count -eq 1 -and (Test-Path (Join-Path $bundle.FullName @($m.WiFi)[0].File))) 'Wi-Fi network saved'
Check (@($m.Bookmarks).Count -eq 1 -and (Test-Path (Join-Path $bundle.FullName @($m.Bookmarks)[0].File))) 'bookmarks saved'
Check (Test-Path (Join-Path $bundle.FullName 'READ ME.txt')) 'READ ME written'

# --- 3. Open it on the "new PC" and unpack the folder and the setting ---
Set-RegValue $testKey 'Choice' 3   # this PC has a different value
Open-Bundle $bundle.FullName; Wait-Jobs
Check ($lvUnpack.Items.Count -ge 3) "unpack list has rows ($($lvUnpack.Items.Count))"
foreach ($it in $lvUnpack.Items) { "  $($it.SubItems[0].Text) | $($it.SubItems[1].Text) | $($it.SubItems[3].Text)" }
$set = $lvUnpack.Items | Where-Object { $_.Tag.Kind -eq 'Setting' -and $_.Tag.Data.Key -eq 'Test' }
Check ($set -and $set.Checked -and $set.SubItems[3].Text -match 'three|3') 'differing setting is offered'
foreach ($it in $lvUnpack.Items) { $it.Checked = $false }
$fold = $lvUnpack.Items | Where-Object { $_.Tag.Kind -eq 'Folder' } | Select-Object -First 1
Check ([bool]$fold) 'folder is offered'
if ($fold) { $fold.Tag.To = $to; $fold.Checked = $true }
if ($set) { $set.Checked = $true }
Start-Unpack; Wait-Jobs
Check ((Get-Content (Join-Path $to 'letter.txt')) -eq 'already on the new PC') 'existing file NOT overwritten'
Check (Test-Path (Join-Path $to 'Sub folder\photo.jpg')) 'new files copied'
Check ((Get-RegValue $testKey 'Choice') -eq 7) 'setting applied'
Check (@(Get-UndoList | Where-Object { $_.N -eq 'Choice' }).Count -ge 1) 'undo recorded'
$todo = @(Get-TodoItems)
Check ([bool]($todo | Where-Object { $_.Text -match 'Some Old Program' })) 'program without winget is on the to-do list'
Check ([bool]($todo | Where-Object { $_.Id -eq 'firefox' })) 'Firefox step on the to-do list'
Check ([bool]($todo | Where-Object { $_.Id -like 'bm|*' })) 'bookmark import step on the to-do list'
"  to do: $(($todo | ForEach-Object Text) -join '; ')"

# Clean up: the test setting's undo entry, the test key and folders.
Save-UndoList @(Get-UndoList | Where-Object { $_.P -ne $testKey })
Remove-Item $testKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($script:TMiss) {
    # Shown texts with no translation. Names, paths, sizes and numbers are fine as they are.
    # Texts already translated (shown text is translated again when it changes) and words that are the same in both languages are fine too.
    $out = New-Object Collections.Generic.HashSet[string]; foreach ($v in $script:TExact.Values) { [void]$out.Add($v) }
    $same = @($script:TExact.Keys | Where-Object { $script:TExact[$_] -ceq $_ })
    $miss = @($script:TMiss | Where-Object { -not $out.Contains($_) -and -not $out.Contains(($_ -split ': ')[0]) -and $_ -notin $same -and $_ -notmatch '^(.+)  \(\d+\)$|^three -> seven$|^Version \d' } | Where-Object { $_ -match '[a-z]{3}' -and $_ -notmatch '^[A-Z]:\\|\\|^\d|github\.com|^PC Move( \d|$)|^(English|Nederlands|Deutsch|Français|Español|Italiano|Polski)$|^Version: |^Windows: |^Recent errors: ' -and $_ -notin @($lvPack.Items | ForEach-Object { $_.SubItems[1].Text }) -and $_ -notin @($lvUnpack.Items | ForEach-Object { $_.SubItems[1].Text }) } | Sort-Object)
    foreach ($m in $miss) { "  not translated: $m" }
    Check (-not $miss) "every text shown is translated ($Lang)"
}
$errAfter = if (Test-Path $ErrorLogFile) { @(Get-Content $ErrorLogFile).Count } else { 0 }
if ($errAfter -gt $errBefore) { Get-Content $ErrorLogFile -Tail ($errAfter - $errBefore) | ForEach-Object { "  error log: $_" } }
Check ($errAfter -eq $errBefore) 'no errors inside the app'
$JobTimer.Stop()
"`n$(if ($script:Fail) { "$($script:Fail) check(s) FAILED" } else { 'All checks passed.' })"
exit [int]($script:Fail -gt 0)
'@
$src = $src.Replace('[void]$form.ShowDialog()', $harness.Replace('__TIMEOUT__', $TimeoutSec).Replace('$SKIP', $(if ($SkipInventory) { '$true' } else { '$false' })))
$src = $src.Replace("`$Settings = [ordered]@{ Language = 'auto'", "`$Settings = [ordered]@{ Language = '$Language'")
$src = $src.Replace("if (Test-Path `$SettingsFile) {", "if (`$false) {")   # the test ignores this PC's saved settings
$tmp = Join-Path $env:TEMP "pcmove-test-app-$PID.ps1"
[IO.File]::WriteAllText($tmp, $src, (New-Object Text.UTF8Encoding($true)))
$env:PCMOVE_LANGDIR = Join-Path $PSScriptRoot '..\lang'
$env:PCMOVE_TRACKT = $(if ($Language -ne 'en') { '1' } else { '' })
try { & $tmp; $code = $LASTEXITCODE } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
exit $code

