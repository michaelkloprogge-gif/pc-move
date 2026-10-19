# Checks the translation files: one tab per line, the same {n} placeholders on both sides, no line twice,
# and every language has the same English texts as Dutch (lang\nl.tsv is the reference).
# Usage: .\tests\Test-Languages.ps1   (exits 1 if anything is wrong; used by the GitHub build)
$dir = Join-Path $PSScriptRoot '..\lang'
$fail = 0
$keys = @{}
foreach ($f in Get-ChildItem $dir -Filter *.tsv) {
    $seen = New-Object Collections.Hashtable([StringComparer]::Ordinal)   # "Bookmarks" and "bookmarks" are different texts
    $keys[$f.BaseName] = @()
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) {
        $n++
        if (-not $line.Trim()) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -ne 2) { $fail++; "FAIL  $($f.Name):$n  needs exactly one tab: $line"; continue }
        if ($seen[$parts[0]]) { $fail++; "FAIL  $($f.Name):$n  twice: $($parts[0])" }
        $seen[$parts[0]] = $true; $keys[$f.BaseName] += $parts[0]
        $a = @([regex]::Matches($parts[0], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
        $b = @([regex]::Matches($parts[1], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
        if ($a -ne $b) { $fail++; "FAIL  $($f.Name):$n  placeholders differ ($a / $b): $line" }
        if (-not $parts[1].Trim()) { $fail++; "FAIL  $($f.Name):$n  empty translation: $($parts[0])" }
    }
}
$ref = $keys['nl']
foreach ($l in $keys.Keys | Where-Object { $_ -ne 'nl' }) {
    foreach ($k in $ref | Where-Object { $_ -cnotin $keys[$l] }) { $fail++; "FAIL  $l.tsv  missing: $k" }
    foreach ($k in $keys[$l] | Where-Object { $_ -cnotin $ref }) { $fail++; "FAIL  $l.tsv  not in nl.tsv: $k" }
}
if ($fail) { "$fail problem(s)"; exit 1 }
"All $($keys.Count) language files are fine ($($ref.Count) texts each)."
