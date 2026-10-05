[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VpsAddress,

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_.-]{0,31}$')]
    [string]$User,

    [string]$PrivateKey,

    [string]$HostKey
)

$ErrorActionPreference = 'Stop'
$runtimeFiles = @(
    'deploy.sh', 'xray_vps.py', 'README.md'
)
$bootstrap = Join-Path $PSScriptRoot 'bootstrap.sh'
foreach ($name in $runtimeFiles) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "部署目录缺少文件：$name"
    }
}
if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) {
    throw '部署目录缺少 bootstrap.sh。'
}

$pscpCommand = Get-Command pscp.exe -ErrorAction SilentlyContinue
if ($pscpCommand) {
    $pscpPath = $pscpCommand.Source
}
else {
    $pscpPath = @(
        'C:\Program Files\PuTTY\pscp.exe',
        'C:\Program Files (x86)\PuTTY\pscp.exe'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $pscpPath) {
    throw '未找到 pscp.exe。请安装 PuTTY，或把 pscp.exe 放入 PATH。'
}
if ($PrivateKey) { $PrivateKey = (Resolve-Path -LiteralPath $PrivateKey).Path }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("xray-vps-upload-" + [guid]::NewGuid().ToString('N'))
$kitZip = Join-Path $temporaryRoot 'xray-vps-ubuntu22.04-kit.zip'
$checksums = Join-Path $temporaryRoot 'SHA256SUMS.txt'
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipStream = [IO.File]::Open($kitZip, [IO.FileMode]::CreateNew)
    try {
        $zipArchive = New-Object IO.Compression.ZipArchive(
            $zipStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            foreach ($name in $runtimeFiles) {
                $source = Join-Path $PSScriptRoot $name
                $entryName = 'xray-vps-kit/' + $name
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zipArchive,
                    $source,
                    $entryName,
                    [IO.Compression.CompressionLevel]::Optimal
                )
            }
        }
        finally {
            $zipArchive.Dispose()
        }
    }
    finally {
        $zipStream.Dispose()
    }
    $zipCheck = [IO.Compression.ZipFile]::OpenRead($kitZip)
    try {
        $badEntry = $zipCheck.Entries | Where-Object { $_.FullName.Contains('\') } | Select-Object -First 1
        if ($badEntry) {
            throw "ZIP 内部路径包含反斜杠：$($badEntry.FullName)"
        }
    }
    finally {
        $zipCheck.Dispose()
    }
    $hash = (Get-FileHash -LiteralPath $kitZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText(
        $checksums,
        "$hash  xray-vps-ubuntu22.04-kit.zip`n",
        [Text.Encoding]::ASCII
    )
    Write-Host "临时部署包已生成并计算 SHA256：$hash"

    $remoteHost = if ($VpsAddress.Contains(':') -and -not $VpsAddress.StartsWith('[')) {
        "[$VpsAddress]"
    }
    else {
        $VpsAddress
    }
    $destination = "${User}@${remoteHost}:./"
    $pscpArguments = @('-P', $SshPort)
    if ($PrivateKey) { $pscpArguments += @('-i', $PrivateKey) }
    if ($HostKey) { $pscpArguments += @('-hostkey', $HostKey) }
    $pscpArguments += @($kitZip, $checksums, $bootstrap, $destination)

    Write-Host "正在通过 $pscpPath 上传脚本包；不会上传 Xray 核心、凭据或本地配置。"
    & $pscpPath @pscpArguments
    if ($LASTEXITCODE -ne 0) { throw "pscp 上传失败，退出码：$LASTEXITCODE" }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp) -like 'xray-vps-upload-*') {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '上传完成。回到当前 PuTTY 窗口，依次运行：'
Write-Host '  sudo bash "$HOME/bootstrap.sh" --source-dir "$HOME"'
Write-Host '  sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh preflight'
Write-Host '  sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh install'
