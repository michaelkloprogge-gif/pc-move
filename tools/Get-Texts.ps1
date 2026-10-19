# Lists the English texts in pc-move.ps1 that reach the screen, in the form the translation tables use:
# "$x item(s)" becomes "{0} item(s)". Use it to find texts a lang\<code>.tsv file is missing.
# Usage: .\tools\Get-Texts.ps1 [-Missing nl]
param([string]$Missing)
$app = Join-Path $PSScriptRoot '..\pc-move.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($app, [ref]$null, [ref]$null)
# Not screen text: paths, registry keys, regexes, command lines, ids, file names.
$skip = '^(HK|ms-|https?:|[A-Za-z]:\\|\\|/|\.|-|\^|\(\?|\[|\$|%)|\\\\|\.(ps1|exe|json|xml|txt|html|tsv|lnk|log|dll)\b|^[\w.-]+$|^(Segoe|Consolas)|WScript|DarkMode|^PC Move bundle$|^\{0\}$|`'
$words = 'Start', 'Settings', 'Unpack', 'Program', 'Folder', 'Setting', 'Bookmarks', 'Cancel', 'Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites', 'What', 'Item', 'Size', 'Note', 'Status', 'Step', 'Why', 'Light', 'Dark', 'English', 'Language', 'Theme', 'Undo', 'Updates', 'Install', 'Uninstall', 'Files', 'About', 'dark', 'light', 'shown', 'hidden', 'icon', 'Home', 'done', 'installed', 'empty', 'bookmarks', 'Stopping...', 'Unpacking', 'Downloading...'
$texts = New-Object Collections.Generic.HashSet[string]
foreach ($n in $ast.FindAll({ $args[0] -is [Management.Automation.Language.StringConstantExpressionAst] -or $args[0] -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
    if ($n.Parent -is [Management.Automation.Language.ExpandableStringExpressionAst]) { continue }
    if ($n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'BareWord') { continue }
    $t = if ($n -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
        $s = $n.Value; $i = 0
        # Replace each $var / $(...) with {0}, {1}... in order.
        foreach ($e in @($n.NestedExpressions | Sort-Object { $_.Extent.StartOffset } -Descending)) {
            $rel = $e.Extent.StartOffset - $n.Extent.StartOffset - 1
            if ($rel -lt 0 -or $rel + $e.Extent.Text.Length -gt $s.Length) { continue }
            $s = $s.Substring(0, $rel) + '{#}' + $s.Substring($rel + $e.Extent.Text.Length)
        }
        while ($s -match '\{#\}') { $s = ([regex]'\{#\}').Replace($s, "{$i}", 1); $i++ }
        $s
    } else { $n.Value }
    foreach ($line in $t -split "`r?`n|``n") {
        $line = $line.Trim() -replace '^(- |\d\.\s+)', ''
        if ($line.Length -lt 3 -or $line -notmatch '[a-z]') { continue }
        if ($line -match $skip) { if ($line -notin $words) { continue } }
        if ($line -notmatch '\s' -and $line -cnotin $words) { continue }
        [void]$texts.Add($line)
    }
}
$all = @($texts | Sort-Object)
if ($Missing) {
    $have = @{}
    foreach ($l in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot "..\lang\$Missing.tsv"), [Text.Encoding]::UTF8)) { $have[($l -split "`t")[0]] = 1 }
    $all | Where-Object { -not $have[$_] }
} else { $all }
