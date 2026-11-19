# Builds the Windows installers from dist\ (scripts/build.sh first).
#   scripts\installer.ps1 -Version 1.2.3 [-Arch x64,arm64] [-RequireSign] [-JsignJar path]
#
# Signing (Authenticode, SSL.com eSigner through jsign) is on when all four
# of ESIGNER_USERNAME, ESIGNER_PASSWORD, ESIGNER_CREDENTIAL_ID and
# ESIGNER_TOTP_SECRET are set; unsigned when none is (SmartScreen warns on
# first run). Some but not all is an error, and so is none with -RequireSign.
# Optional: JSIGN_JAR (or -JsignJar; default C:\Users\renaud\tools\jsign\jsign-7.6.jar),
# JAVA (default: java on the PATH; a JDK/JRE 11+), ESIGNER_KEYSTORE (the
# eSigner service; https://cs-try.ssl.com for the sandbox).
#
# Signed, in order: the four dist\windows-*\*.exe, then each installer and
# the uninstaller it embeds (Inno's SignTool). Every signed file is then
# verified, and the checksums and the update feed are written last so they
# match the signed bytes. The secrets never reach a command line or a log:
# jsign reads them from the environment (--storepass/--keypass env:NAME).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string[]]$Arch = @("x64", "arm64"),
    [switch]$RequireSign,
    [string]$JsignJar
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"

# --- What signing needs ----------------------------------------------------
$signVars = @("ESIGNER_USERNAME", "ESIGNER_PASSWORD", "ESIGNER_CREDENTIAL_ID", "ESIGNER_TOTP_SECRET")
$present = @($signVars | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) })
$missing = @($signVars | Where-Object { $present -notcontains $_ })
if ($present.Count -gt 0 -and $missing.Count -gt 0) {
    throw "signing is half-configured: $($missing -join ', ') not set (set all of $($signVars -join ', '), or none for an unsigned build)"
}
$sign = $present.Count -eq $signVars.Count
if (-not $sign -and $RequireSign) {
    throw "-RequireSign: signing isn't configured (set $($signVars -join ', '))"
}

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 isn't installed (winget install --id JRSoftware.InnoSetup -e --scope user)" }

$binaries = @(Get-ChildItem "$dist\windows-*\*.exe")
if ($binaries.Count -eq 0) { throw "no executables in $dist\windows-*\ (run scripts/build.sh first)" }

# The Windows SDK's signtool, for verification only (jsign 7.6 can't verify).
function Find-SignTool {
    $sdkArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\$sdkArch\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

function Assert-Signed([string[]]$Files) {
    $signtool = Find-SignTool
    foreach ($f in $Files) {
        if ($signtool) {
            & $signtool verify /pa /v $f
            if ($LASTEXITCODE -ne 0) { throw "signature check failed: $f" }
        } else {
            $s = Get-AuthenticodeSignature -FilePath $f
            if ($s.Status -ne "Valid") { throw "signature check failed: $f ($($s.Status): $($s.StatusMessage))" }
            Write-Host "verified: $f ($($s.SignerCertificate.Subject))"
        }
    }
}

# --- Sign the executables ----------------------------------------------------
$signArgs = @()
if ($sign) {
    if (-not $JsignJar) {
        $JsignJar = if ($env:JSIGN_JAR) { $env:JSIGN_JAR } else { "C:\Users\renaud\tools\jsign\jsign-7.6.jar" }
    }
    if (-not (Test-Path $JsignJar)) { throw "jsign not found at $JsignJar (set JSIGN_JAR or -JsignJar)" }
    $javaCmd = Get-Command $(if ($env:JAVA) { $env:JAVA } else { "java" }) -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $javaCmd) { throw "Java not found (put a JDK 11+ on the PATH or set JAVA)" }
    $java = $javaCmd.Source

    # Only names of variables go on the command line; jsign reads the values.
    $jsignFlags = @(
        "--storetype", "ESIGNER",
        "--storepass", "env:JSIGN_STOREPASS",
        "--keypass", "env:ESIGNER_TOTP_SECRET",
        "--alias", $env:ESIGNER_CREDENTIAL_ID,
        "--alg", "SHA-256",
        "--tsaurl", "http://ts.ssl.com",
        "--tsmode", "RFC3161",
        "--replace"
    )
    if ($env:ESIGNER_KEYSTORE) { $jsignFlags += @("--keystore", $env:ESIGNER_KEYSTORE) }
    $env:JSIGN_STOREPASS = "$env:ESIGNER_USERNAME|$env:ESIGNER_PASSWORD"

    # Inno's SignTool: $q is a quote, $f the file it signs (quoted by Inno).
    $quoted = $jsignFlags | ForEach-Object { if ($_ -match '[\s"]') { '$q' + $_ + '$q' } else { $_ } }
    $signArgs = @("/DSign", "/Ssigntool=`$q$java`$q -jar `$q$JsignJar`$q $($quoted -join ' ') `$f")
}

try {
    if ($sign) {
        foreach ($b in $binaries) {
            Write-Host "signing $($b.FullName)"
            & $java -jar $JsignJar @jsignFlags $b.FullName
            if ($LASTEXITCODE -ne 0) { throw "signing $($b.Name) failed" }
        }
    } else {
        Write-Warning "unsigned build (no ESIGNER_* credentials): SmartScreen will warn on first run"
    }

    # --- The installers (signed with their uninstaller by ISCC) -------------
    $installers = @()
    foreach ($a in $Arch) {
        & $iscc "/DAppVersion=$Version" "/DArch=$a" @signArgs "$root\installer\BromureSidecar.iss"
        if ($LASTEXITCODE -ne 0) { throw "ISCC failed for $a" }
        $installers += "$dist\BromureSidecar-$Version-$a.exe"
    }
} finally {
    Remove-Item Env:JSIGN_STOREPASS -ErrorAction SilentlyContinue
}

if ($sign) {
    Assert-Signed (@($binaries.FullName) + $installers)
}

# --- Checksums, after signing ------------------------------------------------
# build.sh's SHA256SUMS: the Windows binaries' lines get their signed hashes.
$sums = Join-Path $dist "SHA256SUMS"
if (Test-Path $sums) {
    (Get-Content $sums) | ForEach-Object {
        if ($_ -match '^([0-9a-fA-F]{64}) ([ *])(\./windows-.+)$') {
            $file = Join-Path $dist ($Matches[3].Substring(2))
            "$((Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()) $($Matches[2])$($Matches[3])"
        } else { $_ }
    } | Set-Content -Encoding ascii $sums
}
Get-ChildItem "$dist\BromureSidecar-$Version-*.exe" | ForEach-Object {
    $h = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLower()
    "$h  $($_.Name)"
} | Set-Content -Encoding ascii "$dist\installers-SHA256SUMS"
Get-Content "$dist\installers-SHA256SUMS"

# The update feed the Sidecar's updater reads (internal/updater): this
# version and, per architecture, the versioned installer's URL and SHA-256.
# Published as latest.json beside the installers.
$feedBase = if ($env:FEED_BASE) { $env:FEED_BASE } else { "https://dl.bromure.io/releases-sidecar-windows" }
$entry = {
    param($a)
    $f = "$dist\BromureSidecar-$Version-$a.exe"
    if (Test-Path $f) {
        @{ url = "$feedBase/BromureSidecar-$Version-$a.exe"; sha256 = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower() }
    }
}
$x64 = & $entry "x64"
$arm = & $entry "arm64"
$feed = [ordered]@{ version = $Version }
if ($x64) { $feed.url = $x64.url; $feed.sha256 = $x64.sha256 }
if ($arm) { $feed.arm64 = $arm }
$feed | ConvertTo-Json | Set-Content -Encoding utf8NoBOM "$dist\latest-$Version.json"
Write-Host "feed: dist\latest-$Version.json"
