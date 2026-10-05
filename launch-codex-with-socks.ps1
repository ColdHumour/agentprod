[CmdletBinding()]
param(
    [string]$ProxyHost = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$ProxyPort = 10808,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

# Package activation does not inherit the caller's environment. Pass only the
# explicit launcher settings to a hidden helper, then create the desktop child.
function New-CodexPackageHelperArguments {
    param([string]$ExecutablePath, [string]$Arguments, [hashtable]$Environment, [string]$ResultPath)
    $payload = @{
        ExecutablePath = $ExecutablePath
        Arguments = $Arguments
        Environment = $Environment
        ResultPath = $ResultPath
    } | ConvertTo-Json -Compress -Depth 4
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $helper = @'
$ErrorActionPreference = 'Stop'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
try {
    foreach ($entry in $payload.Environment.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process')
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $payload.ExecutablePath
    $start.Arguments = $payload.Arguments
    $start.WorkingDirectory = Split-Path $payload.ExecutablePath -Parent
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $child = [System.Diagnostics.Process]::Start($start)
    $result = @{ StartedPid = $child.Id }
    $child.Dispose()
} catch { $result = @{ Error = $_.Exception.Message } }
$json = $result | ConvertTo-Json -Compress
$temporaryResult = $payload.ResultPath + '.tmp'
[IO.File]::WriteAllText($temporaryResult, $json)
[IO.File]::Move($temporaryResult, $payload.ResultPath)
'@
    $helper = $helper.Replace('__PAYLOAD__', $payloadBase64)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
    return '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
}

# App package names and executable names can differ across desktop releases.
function Find-CodexDesktop {
    try {
        $packages = @(Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction Stop |
            Sort-Object { [version]$_.Version } -Descending)
    }
    catch {
        Write-Warning "Could not query the installed app package: $($_.Exception.Message)"
        $packages = @()
    }
    foreach ($package in $packages) {
        if (-not $package.InstallLocation) { continue }
        $manifestPath = Join-Path $package.InstallLocation "AppxManifest.xml"
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
                foreach ($application in $manifest.Package.Applications.Application) {
                    $relativeExe = [string]$application.Executable
                    if ($relativeExe -match '(^|[\\/])(ChatGPT|Codex)\.exe$') {
                        $candidate = Join-Path $package.InstallLocation $relativeExe
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
                    }
                }
            }
            catch { Write-Warning "Could not read app manifest: $($_.Exception.Message)" }
        }
        foreach ($name in @("ChatGPT.exe", "Codex.exe")) {
            $candidate = Join-Path $package.InstallLocation "app\$name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    # Useful for diagnostics when package registration is unavailable to this account.
    foreach ($process in @(Get-Process -Name "ChatGPT", "Codex" -ErrorAction SilentlyContinue)) {
        $candidate = $process.Path
        if ($candidate -like '*\WindowsApps\OpenAI.Codex_*\app\*.exe' -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    foreach ($cli in @(Get-Command "codex.exe" -All -ErrorAction SilentlyContinue)) {
        if ($cli.Path -notlike '*\WindowsApps\OpenAI.Codex_*\app\resources\codex.exe') { continue }
        $appDirectory = Split-Path (Split-Path $cli.Path -Parent) -Parent
        foreach ($name in @("ChatGPT.exe", "Codex.exe")) {
            $candidate = Join-Path $appDirectory $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    throw "Could not find the Codex desktop app. Confirm OpenAI.Codex is installed for this Windows account."
}

try {
# BEGIN CODEX CACHE MIGRATION MANAGED ENV
$codexCacheRoot = "F:\workspace\.codex-cache"
$codexCacheDirectories = @(
    (Join-Path $codexCacheRoot "shell-temp"),
    (Join-Path $codexCacheRoot "npm-cache"),
    (Join-Path $codexCacheRoot "pip-cache")
)
foreach ($directory in $codexCacheDirectories) {
    if (Test-Path -LiteralPath $directory -PathType Leaf) {
        throw "A file occupies the cache directory path: $directory"
    }
    if (-not $CheckOnly -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}
$codexRuntimeJunction = "C:\Users\coldhumour\.cache\codex-runtimes"
$codexRuntimeTarget = Join-Path $codexCacheRoot "codex-runtimes"
if (-not (Test-Path -LiteralPath (Join-Path $codexRuntimeTarget "codex-primary-runtime\runtime.json") -PathType Leaf)) {
    throw "The F-drive Codex runtime target is unavailable or incomplete: $codexRuntimeTarget"
}
if (-not (Test-Path -LiteralPath $codexRuntimeJunction -PathType Container)) {
    throw "The C-drive Codex runtime compatibility path is missing: $codexRuntimeJunction"
}
$codexRuntimeItem = Get-Item -LiteralPath $codexRuntimeJunction -Force
if (-not ($codexRuntimeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Codex runtime mapping changed: expected an NTFS junction at $codexRuntimeJunction. No automatic repair was attempted."
}
$codexRuntimeTargets = @($codexRuntimeItem.Target)
$codexExpectedRuntimeTarget = [System.IO.Path]::GetFullPath($codexRuntimeTarget).TrimEnd("\")
$codexActualRuntimeTarget = if ($codexRuntimeTargets.Count -eq 1) { [System.IO.Path]::GetFullPath([string]$codexRuntimeTargets[0]).TrimEnd("\") } else { "" }
if (-not [string]::Equals($codexActualRuntimeTarget, $codexExpectedRuntimeTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Codex runtime junction target changed. Expected $codexExpectedRuntimeTarget but found $codexActualRuntimeTarget. No automatic repair was attempted."
}
# END CODEX CACHE MIGRATION MANAGED ENV

$codexExePath = Find-CodexDesktop
# Running the EXE directly can omit MSIX identity (APPMODEL_ERROR_NO_PACKAGE).
# Resolve the package identity and application ID from this executable's manifest.
$packageRoot = Split-Path (Split-Path $codexExePath -Parent) -Parent
[xml]$packageManifest = Get-Content -LiteralPath (Join-Path $packageRoot "AppxManifest.xml") -Raw
$packageApplication = @($packageManifest.Package.Applications.Application) |
    Where-Object {
        $relativePath = [string]$_.Executable
        $relativePath -and [string]::Equals(
            [System.IO.Path]::GetFullPath((Join-Path $packageRoot $relativePath)),
            [System.IO.Path]::GetFullPath($codexExePath),
            [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
if (-not $packageApplication) { throw "No application identity found for $codexExePath" }
$packageDirectoryName = Split-Path $packageRoot -Leaf
$publisherId = $packageDirectoryName.Split('_')[-1]
$packageFamilyName = "{0}_{1}" -f $packageManifest.Package.Identity.Name, $publisherId
$packageAppId = [string]$packageApplication.Id
if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) {
    throw "Invoke-CommandInDesktopPackage is unavailable. Run this launcher using Windows PowerShell 5.1."
}
$runningDesktop = @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($codexExePath)) -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Path -or $_.Path -eq $codexExePath -or $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\*.exe' })
if ($runningDesktop.Count -gt 0 -and -not $CheckOnly) {
    Write-Host "Codex is already running. Fully quit it from the tray, then run this launcher again." -ForegroundColor Yellow
    Write-Host "A running instance cannot receive new proxy settings. To check without launching, use -CheckOnly."
    exit 2
}

$client = [System.Net.Sockets.TcpClient]::new()
try {
    $connect = $client.ConnectAsync($ProxyHost, $ProxyPort)
    if (-not $connect.Wait(1500) -or -not $client.Connected) {
        throw "Connection timed out."
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = 2000
    $stream.WriteTimeout = 2000
    $stream.Write([byte[]](5, 1, 0), 0, 3)
    if ($stream.ReadByte() -ne 5 -or $stream.ReadByte() -ne 0) {
        throw "The endpoint is not a SOCKS5 proxy accepting connections without authentication."
    }
}
catch {
    throw "SOCKS5 check failed at ${ProxyHost}:${ProxyPort}: $($_.Exception.GetBaseException().Message)"
}
finally {
    $client.Dispose()
}

$proxyAddress = $ProxyHost
if ($proxyAddress.Contains(":") -and -not $proxyAddress.StartsWith("[")) {
    $proxyAddress = "[$proxyAddress]"
}
$proxyUrl = "socks5://${proxyAddress}:${ProxyPort}"

Write-Host "Desktop: $codexExePath"
Write-Host "Package identity: ${packageFamilyName}!${packageAppId}"
Write-Host "SOCKS5: $proxyUrl (handshake OK)"
Write-Host "Runtime mapping: OK"
if ($CheckOnly) {
    Write-Host "Running desktop processes: $($runningDesktop.Count)"
    Write-Host "Checks passed. No application was started or restarted."
    return
}

$env:CODEX_HOME = "C:\Users\coldhumour\.codex"
$env:TEMP = Join-Path $codexCacheRoot "shell-temp"
$env:TMP = $env:TEMP
$env:TMPDIR = $env:TEMP
$env:NPM_CONFIG_CACHE = Join-Path $codexCacheRoot "npm-cache"
$env:PIP_CACHE_DIR = Join-Path $codexCacheRoot "pip-cache"

$env:HTTP_PROXY = $proxyUrl
$env:HTTPS_PROXY = $proxyUrl
$env:ALL_PROXY = $proxyUrl
$env:http_proxy = $proxyUrl
$env:https_proxy = $proxyUrl
$env:all_proxy = $proxyUrl
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = $env:NO_PROXY

$chromiumArguments = @(
    "--proxy-server=$proxyUrl",
    "--proxy-bypass-list=localhost;127.0.0.1;[::1]",
    "--disable-http2",
    "--disable-quic"
)

# Inject settings inside the package context; app activation drops caller env.
$launchEnvironment = @{}
foreach ($name in @('CODEX_HOME', 'TEMP', 'TMP', 'TMPDIR', 'NPM_CONFIG_CACHE', 'PIP_CACHE_DIR',
                    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
    $launchEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$launchResultPath = Join-Path $env:TEMP ('codex-launch-' + [guid]::NewGuid().ToString('N') + '.json')
$helperArguments = New-CodexPackageHelperArguments -ExecutablePath $codexExePath `
    -Arguments ($chromiumArguments -join ' ') -Environment $launchEnvironment -ResultPath $launchResultPath
Invoke-CommandInDesktopPackage -PackageFamilyName $packageFamilyName -AppId $packageAppId `
    -Command "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Args $helperArguments -PreventBreakaway -ErrorAction Stop
$deadline = [DateTime]::UtcNow.AddSeconds(15)
while (-not (Test-Path -LiteralPath $launchResultPath)) {
    if ([DateTime]::UtcNow -gt $deadline) { throw "No response from the package launcher. Result path: $launchResultPath" }
    Start-Sleep -Milliseconds 200
}
$launchResult = Get-Content -LiteralPath $launchResultPath -Raw | ConvertFrom-Json
if ($launchResult.Error) { throw $launchResult.Error }
Write-Host "Started packaged desktop process $($launchResult.StartedPid)."
}
catch {
    Write-Host "Codex launcher failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Diagnostic command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -CheckOnly"
    exit 1
}
