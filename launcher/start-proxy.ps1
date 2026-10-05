# ===== 配置区：通常只需要修改这里 =====
$ExeName = 'gitkraken.exe'       # 与本脚本放在同一文件夹的 exe 文件名
$ProxyHost = '127.0.0.1'         # SOCKS5 代理地址，不带协议和端口
$ProxyPort = 10808               # 改成你的 SOCKS5 监听端口
$ExtraArguments = ''            # 可选额外参数，例如：--disable-gpu
# 此脚本面向 GitKraken；不支持需要用户名/密码的 SOCKS5 代理。
# ===== 配置区结束 =====

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($ExeName) -or
        [IO.Path]::GetFileName($ExeName) -ne $ExeName -or
        [IO.Path]::GetExtension($ExeName) -ine '.exe') {
        throw 'ExeName must be an .exe filename in the script directory.'
    }
    $exePath = Join-Path -Path $PSScriptRoot -ChildPath $ExeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Executable not found: $exePath. Edit ExeName at the top of start-proxy.ps1."
    }
    if ([Uri]::CheckHostName($ProxyHost) -eq [UriHostNameType]::Unknown -or
        $ProxyPort -lt 1 -or $ProxyPort -gt 65535) {
        throw 'Invalid ProxyHost or ProxyPort (expected 1-65535).'
    }

    # 已运行的单实例程序可能忽略新参数，要求先手动退出，不强制结束进程。
    $processName = [IO.Path]::GetFileNameWithoutExtension($ExeName)
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        throw "$ExeName is already running. Exit it completely (including the tray), then retry."
    }

    $proxyBuilder = New-Object System.UriBuilder('socks5', $ProxyHost, $ProxyPort)
    $proxyEndpoint = $proxyBuilder.Uri.Authority
    $browserProxy = 'socks5://' + $proxyEndpoint
    $gitProxy = 'socks5h://' + $proxyEndpoint

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exePath
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    # Chromium 使用 socks5；Git/libcurl 使用 socks5h，让代理解析目标域名。
    # 保留 Chromium 默认的本机回环绕过规则，以兼容本地登录回调。
    $startInfo.Arguments = '--proxy-server="' + $browserProxy + '"'
    if (-not [string]::IsNullOrWhiteSpace($ExtraArguments)) {
        $startInfo.Arguments += ' ' + $ExtraArguments
    }

    # 只修改新进程的环境，不修改系统代理、当前会话或全局 Git 配置。
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        $startInfo.EnvironmentVariables[$name] = $gitProxy
    }
    $startInfo.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1,::1'

    # 为支持这些变量的 Git 子进程添加临时 http.proxy，保留已有配置项。
    $configCount = 0
    $inheritedCount = $startInfo.EnvironmentVariables['GIT_CONFIG_COUNT']
    if (-not [string]::IsNullOrEmpty($inheritedCount)) {
        if (-not [int]::TryParse($inheritedCount, [ref]$configCount) -or
            $configCount -lt 0 -or $configCount -eq [int]::MaxValue) {
            throw 'Inherited GIT_CONFIG_COUNT is invalid.'
        }
    }
    $startInfo.EnvironmentVariables["GIT_CONFIG_KEY_$configCount"] = 'http.proxy'
    $startInfo.EnvironmentVariables["GIT_CONFIG_VALUE_$configCount"] = $gitProxy
    $startInfo.EnvironmentVariables['GIT_CONFIG_COUNT'] = [string]($configCount + 1)

    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw 'Windows did not return a process handle.'
    }
    Write-Host "Started $ExeName with SOCKS5 settings: $proxyEndpoint"
    Write-Host 'Settings passed to the app; actual proxy routing is not verified.'
    $process.Dispose()
    exit 0
}
catch {
    Write-Host ('Launch failed: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
