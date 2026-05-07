# PureCrack Lab Launcher — run this every time (all steps are idempotent)
param([switch]$SkipSetup)

# Self-elevate if not admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    $extraArgs = if ($SkipSetup) { "-SkipSetup" } else { "" }
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $extraArgs"
    exit
}

$root = Split-Path $MyInvocation.MyCommand.Path -Parent
Write-Host "=== PureCrack Lab Setup ===" -ForegroundColor Cyan
Write-Host "Root: $root"

# Strip Mark-of-the-Web from every file under $root.
# Files extracted from a downloaded zip carry a Zone.Identifier ADS that .NET treats
# as a remote source, blocking assembly loads (HRESULT 0x80131515).
Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
Write-Host "[+] Mark-of-the-Web cleared from extracted files" -ForegroundColor Green

if (-not $SkipSetup) {
    # Hosts entries (7 total — all purecoder endpoints → loopback)
    $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsPath -Raw
    $needed = @(
        "127.0.0.1 api.purecoder.io",
        "127.0.0.1 api1.purecoder.io",
        "127.0.0.1 api2.purecoder.io",
        "127.0.0.1 us.purecoder.io",
        "127.0.0.1 eu.purecoder.io",
        "127.0.0.1 us.purecoder.su",
        "127.0.0.1 eu.purecoder.su"
    )
    $added = 0
    foreach ($entry in $needed) {
        $hostname = ($entry -split "\s+")[1]
        if ($hostsContent -notmatch [regex]::Escape($hostname)) {
            Add-Content $hostsPath $entry
            $added++
        }
    }
    Clear-DnsClientCache
    Write-Host "[+] Hosts: $added new entries added (7 total)" -ForegroundColor Green

    # .NET Framework strong-crypto (forces TLS 1.2 for legacy .NET 4.x apps)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
    )
    foreach ($p in $regPaths) {
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        Set-ItemProperty -Path $p -Name "SchUseStrongCrypto"       -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $p -Name "SystemDefaultTlsVersions" -Value 1 -Type DWord -Force
    }
    Write-Host "[+] .NET strong-crypto regkeys set" -ForegroundColor Green

    # TLS cipher suites required by the panel (disabled by default on Win 11)
    $ciphers = @(
        "TLS_DHE_RSA_WITH_AES_128_GCM_SHA256",
        "TLS_DHE_RSA_WITH_AES_256_GCM_SHA384",
        "TLS_DHE_RSA_WITH_AES_128_CBC_SHA",
        "TLS_DHE_RSA_WITH_AES_256_CBC_SHA",
        "TLS_DHE_RSA_WITH_AES_128_CBC_SHA256",
        "TLS_DHE_RSA_WITH_AES_256_CBC_SHA256",
        "TLS_RSA_WITH_3DES_EDE_CBC_SHA"
    )
    foreach ($c in $ciphers) { Enable-TlsCipherSuite -Name $c -ErrorAction SilentlyContinue }
    Write-Host "[+] Cipher suites expanded (DHE-RSA + 3DES)" -ForegroundColor Green
}

# Ensure data\ exists so PureCrack can write certs there on first run
$null = New-Item -Path (Join-Path $root "data") -ItemType Directory -Force

# Inject PureHelper plugin into Settings.json with correct absolute path
# (the panel stores FilePath as absolute, so we recompute it every launch)
$settingsPath = Join-Path $root "panel\data\Settings.json"
$pluginPath   = Join-Path $root "panel\Plugins\PureHelper.dll"
if ((Test-Path $settingsPath) -and (Test-Path $pluginPath)) {
    $content     = Get-Content $settingsPath -Raw
    $escapedPath = $pluginPath -replace '\\', '\\\\'
    $newEntry    = '"CustomPlugins": [{"Name": "PureHelper","FilePath": "' + $escapedPath + '"}]'
    $content     = [regex]::Replace($content, '"CustomPlugins"\s*:\s*\[[\s\S]*?\]', $newEntry)
    [System.IO.File]::WriteAllText($settingsPath, $content, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "[+] Plugin injected -> $pluginPath" -ForegroundColor Green
} else {
    if (-not (Test-Path $settingsPath)) { Write-Host "[!] Settings.json missing" -ForegroundColor Yellow }
    if (-not (Test-Path $pluginPath))   { Write-Host "[!] PureHelper.dll missing" -ForegroundColor Yellow }
}

# Tell PureCrack where Settings.json lives (enables IPs reorder)
$env:PURE_SETTINGS_JSON = $settingsPath
Write-Host "[+] PURE_SETTINGS_JSON -> $settingsPath" -ForegroundColor Green

# Kill any stale PureRAT processes (can't have two running at once)
$stale = Get-Process -Name PureRAT -ErrorAction SilentlyContinue
if ($stale) {
    $stale | Stop-Process -Force
    Write-Host "[+] Killed $($stale.Count) stale PureRAT process(es)" -ForegroundColor Yellow
}

# Launch PureCrack
$pureCrack = Join-Path $root "PureCrack.exe"
if (-not (Test-Path $pureCrack)) {
    Write-Host "[!] PureCrack.exe not found at $pureCrack" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "[*] Launching PureCrack..." -ForegroundColor Cyan
& $pureCrack
