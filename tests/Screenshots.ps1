# Opens PC Move for real, visits every page and saves a picture of each to docs\screenshots (or -Out).
# The Pack up page really looks at this PC, so it takes about a minute. Nothing is changed.
# Usage: powershell -STA -File .\tests\Screenshots.ps1 [-Language nl] [-Theme dark] [-Out folder]
param([string]$Language = 'en', [string]$Theme = 'light', [string]$Out = (Join-Path $PSScriptRoot '..\docs\screenshots'), [int]$Width, [int]$Height)
New-Item -ItemType Directory -Force $Out | Out-Null
$src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\pc-move.ps1'))
$harness = @'
function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') { if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' } }
function Snap([string]$Name) {
    for ($i = 0; $i -lt 10; $i++) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path '__OUT__' "$Name.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Wait-Jobs { $d = (Get-Date).AddSeconds(300); do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } while ($script:Jobs.Count -and (Get-Date) -lt $d) }
$form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-3000, 0)   # off screen
$form.Show()
__SIZE__Snap 'start'
Show-Page $pgPack; Wait-Jobs
$script:PackDest = 'E:\'; Update-PackSummary
Snap 'pack-up'
Show-Page $pgTodo; Snap 'to-do-empty'
Show-Page $pgSet; Snap 'settings'
$form.Close()
$JobTimer.Stop()
'@
$size = if ($Width -and $Height) { "`$form.MinimumSize = New-Object Drawing.Size(0, 0); `$form.Size = New-Object Drawing.Size($Width, $Height)`n" } else { '' }   # -Width/-Height: e.g. 1440x900 for the Microsoft Store
$src = $src.Replace('[void]$form.ShowDialog()', $harness.Replace('__OUT__', (Resolve-Path $Out).Path).Replace('__SIZE__', $size))
$src = $src.Replace("`$Settings = [ordered]@{ Language = 'auto'; Theme = 'system'", "`$Settings = [ordered]@{ Language = '$Language'; Theme = '$Theme'")
$src = $src.Replace("if (Test-Path `$SettingsFile) {", "if (`$false) {")
$src = $src.Replace("`$form.Add_Shown({", "`$null = ({")   # no update check
$tmp = Join-Path $env:TEMP "pcmove-shots-$PID.ps1"
[IO.File]::WriteAllText($tmp, $src, (New-Object Text.UTF8Encoding($true)))
$env:PCMOVE_LANGDIR = Join-Path $PSScriptRoot '..\lang'
try { & $tmp } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
"Saved to $Out"
