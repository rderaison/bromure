<#
.SYNOPSIS
    macOS ↔ Windows parity check.

.DESCRIPTION
    Walks every C# / XAML / shell file under windows/ looking for an
    anchor comment of the form

        macos-source: Sources/AgentCoding/Foo.swift @ <12-hex blob sha>

    For each anchor, compares the recorded blob SHA against the macOS
    file's CURRENT blob SHA via `git rev-parse HEAD:<path>`.

      * If the SHA changed → DRIFT (the macOS source has evolved since
        the Windows port was last synced; review the diff and refresh
        the anchor).
      * Sources/AgentCoding/*.swift with no anchor anywhere → UNPORTED
        (unless listed in windows/PARITY_IGNORE).

    Exit code: 0 on full parity, 1 on any drift / unported file.

.NOTES
    Run from the repo root:  pwsh windows/scripts/check-parity.ps1

    Anchor format in C#:    // macos-source: Sources/.../Foo.swift @ a1b2c3d4
                            //   plus subsequent lines if multiple swift sources
    Anchor format in XAML:  <!-- macos-source: ... @ ... -->
    Anchor format in sh:    # macos-source: ... @ ...
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# Locate the repo root (script lives at <repo>/windows/scripts/).
$repoRoot = (& git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
    Write-Host "ERROR: not in a git working tree" -ForegroundColor Red
    exit 2
}
$srcRoot = Join-Path $repoRoot 'Sources/AgentCoding'
$winRoot = Join-Path $repoRoot 'windows'
$ignoreFile = Join-Path $winRoot 'PARITY_IGNORE'

# 1) Collect anchors from the Windows tree.
$anchorRegex = [regex]'macos-source:\s*(Sources/AgentCoding/\S+\.(?:swift|sh))\s*@\s*([a-f0-9]{8,40})'
$anchors = @{}
$winFiles = Get-ChildItem -Path $winRoot -Recurse -File -Include *.cs,*.xaml,*.sh,*.ps1 |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
foreach ($f in $winFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $anchorRegex.Matches($text)) {
        $swift = $m.Groups[1].Value
        $sha = $m.Groups[2].Value.Substring(0, [Math]::Min(12, $m.Groups[2].Value.Length))
        if (-not $anchors.ContainsKey($swift)) { $anchors[$swift] = @() }
        $relWin = $f.FullName.Substring($repoRoot.Length + 1).Replace('\','/')
        $anchors[$swift] += [pscustomobject]@{ Windows = $relWin; Sha = $sha }
    }
}

# 2) Compare each anchor's recorded SHA against the current blob SHA.
$drift = @()
foreach ($swift in $anchors.Keys | Sort-Object) {
    $current = & git rev-parse "HEAD:$swift" 2>$null
    if (-not $current) {
        # Anchor refers to a deleted macOS file → still drift
        foreach ($entry in $anchors[$swift]) {
            $drift += [pscustomobject]@{
                Swift = $swift; Windows = $entry.Windows; Was = $entry.Sha; Now = '<deleted>'
            }
        }
        continue
    }
    $current = $current.Trim().Substring(0, 12)
    foreach ($entry in $anchors[$swift]) {
        if ($entry.Sha -ne $current) {
            $drift += [pscustomobject]@{
                Swift = $swift; Windows = $entry.Windows; Was = $entry.Sha; Now = $current
            }
        }
    }
}

# 3) Find unported macOS files.
$ignored = @()
if (Test-Path $ignoreFile) {
    $ignored = Get-Content $ignoreFile |
        ForEach-Object {
            # Strip inline comments (everything from `#` onward) then trim.
            $hash = $_.IndexOf('#')
            $line = if ($hash -ge 0) { $_.Substring(0, $hash) } else { $_ }
            $line.Trim()
        } |
        Where-Object { $_ }
}
$unported = @()
$swiftFiles = Get-ChildItem -Path $srcRoot -Recurse -Filter *.swift -File
foreach ($s in $swiftFiles) {
    $rel = $s.FullName.Substring($repoRoot.Length + 1).Replace('\','/')
    if ($anchors.ContainsKey($rel)) { continue }
    if ($ignored -contains $rel) { continue }
    $unported += $rel
}

# 4) Report.
$matched = $anchors.Count
Write-Host ""
Write-Host "macOS ↔ Windows parity" -ForegroundColor Cyan
Write-Host ("  matched: {0}  drift: {1}  unported: {2}  ignored: {3}" -f $matched, $drift.Count, $unported.Count, $ignored.Count)

if ($drift.Count -gt 0) {
    Write-Host ""
    Write-Host "DRIFT — macOS source has changed since the anchor was recorded:" -ForegroundColor Yellow
    foreach ($d in $drift | Sort-Object Swift) {
        Write-Host ("  {0}" -f $d.Swift)
        Write-Host ("    was {0} → now {1}" -f $d.Was, $d.Now) -ForegroundColor Yellow
        Write-Host ("    {0}" -f $d.Windows) -ForegroundColor DarkGray
        if ($Verbose) {
            Write-Host ""
            Write-Host "    diff (Sources tree, was → now):" -ForegroundColor DarkGray
            $oldSha = $d.Was
            $newSha = $d.Now
            if ($newSha -ne '<deleted>') {
                & git --no-pager diff $oldSha $newSha -- $d.Swift 2>$null |
                    Select-Object -First 30 |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
            }
        }
    }
}

if ($unported.Count -gt 0) {
    Write-Host ""
    Write-Host "UNPORTED — Sources/AgentCoding/*.swift with no Windows anchor:" -ForegroundColor Yellow
    foreach ($u in $unported | Sort-Object) {
        Write-Host "  $u" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Add an anchor to a Windows file or list the path in" -ForegroundColor DarkGray
    Write-Host "  windows/PARITY_IGNORE if there is no plan to port it." -ForegroundColor DarkGray
}

Write-Host ""
if ($drift.Count -eq 0 -and $unported.Count -eq 0) {
    Write-Host "OK — full parity" -ForegroundColor Green
    exit 0
}
exit 1
