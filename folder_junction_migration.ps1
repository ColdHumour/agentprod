#requires -Version 5.1

<#
.SYNOPSIS
Safely copies a physical directory to another local NTFS volume and replaces
the original directory with an NTFS junction.

.DESCRIPTION
The script is action-based and self-contained. Run the entire file for each
action. It never deletes the backup or the target directory.

ProcessName is optional. If supplied, matching processes must be stopped.
Copy, Switch, and Rollback always require a manual CLOSED confirmation as an
additional safety check.

.EXAMPLE
.\folder_junction_migration.ps1 -Action Audit `
    -Source "$env:APPDATA\Notion" `
    -Target 'D:\ProgramData\NotionData' `
    -ProcessName Notion `
    -HashRelativePath 'notion.db','state.json','Preferences'

.EXAMPLE
.\folder_junction_migration.ps1 -Action Copy `
    -Source 'C:\Path\Source' `
    -Target 'D:\Path\Target'

.EXAMPLE
.\folder_junction_migration.ps1 -Action Rollback `
    -Source 'C:\Path\Source' `
    -Target 'D:\Path\Target' `
    -Backup 'C:\Path\Source.backup-20260902-180000'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Audit', 'Copy', 'Switch', 'Status', 'Rollback')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Target,

    [string[]]$ProcessName = @(),

    [string[]]$HashRelativePath = @(),

    [string]$Backup = ''
)

Set-StrictMode -Version Latest

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

function Convert-ToNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path cannot be empty.'
    }

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Parent
    )

    return $Path.StartsWith(
        $Parent.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Test-ReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        $Item
    )

    return (
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    )
}

function Get-DriveInfoForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch '^[A-Za-z]:\\') {
        throw "Path must be an absolute drive-letter path: $Path"
    }

    $driveName = "$($Path.Substring(0, 1)):\"
    $drive = [IO.DriveInfo]::GetDrives() |
        Where-Object {
            $_.Name.Equals(
                $driveName,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        Select-Object -First 1

    if ($null -eq $drive -or -not $drive.IsReady) {
        throw "Drive is missing or not ready: $driveName"
    }

    return $drive
}

function Assert-NotBroadPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $root = [IO.Path]::GetPathRoot($Path).TrimEnd('\')

    if ($Path.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label cannot be a volume root: $Path"
    }

    $blockedPaths = @(
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        $env:APPDATA,
        $env:LOCALAPPDATA
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Convert-ToNormalizedPath $_ }

    foreach ($blockedPath in $blockedPaths) {
        if ($Path.Equals(
            $blockedPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "$Label is too broad or system-sensitive: $Path"
        }
    }
}

function Assert-PathRelationship {
    Assert-NotBroadPath -Path $Source -Label 'Source'
    Assert-NotBroadPath -Path $Target -Label 'Target'

    $sourceDrive = Get-DriveInfoForPath -Path $Source
    $targetDrive = Get-DriveInfoForPath -Path $Target

    if ($sourceDrive.DriveFormat -ne 'NTFS') {
        throw "Source volume is not NTFS: $($sourceDrive.DriveFormat)"
    }

    if ($targetDrive.DriveFormat -ne 'NTFS') {
        throw "Target volume is not NTFS: $($targetDrive.DriveFormat)"
    }

    if ($sourceDrive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'Source volume is not a fixed local disk.'
    }

    if ($targetDrive.DriveType -ne [IO.DriveType]::Fixed) {
        throw 'Target volume is not a fixed local disk.'
    }

    if ($sourceDrive.Name -ieq $targetDrive.Name) {
        throw 'Source and Target must be on different volumes.'
    }

    if (
        (Test-PathInside -Path $Target -Parent $Source) -or
        (Test-PathInside -Path $Source -Parent $Target)
    ) {
        throw 'Source and Target cannot contain each other.'
    }

    if (Test-Path -LiteralPath $Target) {
        $targetItem = Get-Item -LiteralPath $Target -Force

        if (-not $targetItem.PSIsContainer) {
            throw "Target exists but is not a directory: $Target"
        }

        if (Test-ReparsePoint -Item $targetItem) {
            throw "Target itself must not be a reparse point: $Target"
        }
    }
}

function Assert-PhysicalSource {
    Assert-PathRelationship

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source directory does not exist: $Source"
    }

    $sourceItem = Get-Item -LiteralPath $Source -Force

    if (Test-ReparsePoint -Item $sourceItem) {
        throw "Source is already a reparse point: $Source"
    }

    $firstItem = Get-ChildItem -LiteralPath $Source -Force |
        Select-Object -First 1

    if ($null -eq $firstItem) {
        throw 'Source is empty. There is nothing to migrate.'
    }
}

function Assert-TargetEmpty {
    if (-not (Test-Path -LiteralPath $Target)) {
        return
    }

    $firstItem = Get-ChildItem -LiteralPath $Target -Force |
        Select-Object -First 1

    if ($null -ne $firstItem) {
        throw @"
Target is not empty: $Target

Do not delete it blindly. Inspect it or choose a new empty Target.
"@
    }
}

function Get-MatchingProcesses {
    $matches = @()

    foreach ($name in $ProcessName) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $matches += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    return @($matches | Sort-Object Id -Unique)
}

function Confirm-SourceUnused {
    $matchingProcesses = @(Get-MatchingProcesses)

    if ($matchingProcesses.Count -gt 0) {
        $matchingProcesses |
            Select-Object Id, ProcessName |
            Format-Table -AutoSize

        throw 'Matching processes are still running.'
    }

    Write-Host ''
    Write-Host "Source: $Source"

    if ($ProcessName.Count -gt 0) {
        Write-Host "Checked process names: $($ProcessName -join ', ')"
    }
    else {
        Write-Host 'No process names were supplied for automatic checking.'
    }

    Write-Host 'Confirm every application that may use Source is fully closed.'

    $confirmation = Read-Host 'Type uppercase CLOSED to continue'

    if ($confirmation -cne 'CLOSED') {
        throw 'Source-use confirmation cancelled.'
    }
}

function Get-DirectoryStatistics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stats = Get-ChildItem `
        -LiteralPath $Path `
        -Recurse `
        -Force `
        -File |
        Measure-Object -Property Length -Sum

    return [pscustomobject]@{
        Files = [int64]$stats.Count
        Bytes = [int64]$stats.Sum
    }
}

function Assert-SafeRelativeHashPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "HashRelativePath must be relative: $RelativePath"
    }

    $combined = Convert-ToNormalizedPath (Join-Path $Source $RelativePath)

    if (-not (Test-PathInside -Path $combined -Parent $Source)) {
        throw "HashRelativePath escapes Source: $RelativePath"
    }
}

function Invoke-ExactCopyVerification {
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'

    & $robocopy $Source $Target `
        /E `
        /L `
        /COPY:DAT `
        /DCOPY:DAT `
        /XJ `
        /R:0 `
        /W:0 `
        /NFL `
        /NDL `
        /NJH `
        /NJS `
        /NP

    $verificationCode = $LASTEXITCODE

    if ($verificationCode -ne 0) {
        throw @"
Source and Target are not identical according to Robocopy.
Verification exit code: $verificationCode

Do not run Switch.
"@
    }

    $sourceStats = Get-DirectoryStatistics -Path $Source
    $targetStats = Get-DirectoryStatistics -Path $Target

    if (
        $sourceStats.Files -ne $targetStats.Files -or
        $sourceStats.Bytes -ne $targetStats.Bytes
    ) {
        throw @"
File count or byte count differs.

Source files: $($sourceStats.Files)
Target files: $($targetStats.Files)
Source bytes: $($sourceStats.Bytes)
Target bytes: $($targetStats.Bytes)
"@
    }

    foreach ($relativePath in $HashRelativePath) {
        Assert-SafeRelativeHashPath -RelativePath $relativePath

        $sourceFile = Join-Path $Source $relativePath
        $targetFile = Join-Path $Target $relativePath

        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "Hash source file does not exist: $relativePath"
        }

        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
            throw "Hash target file does not exist: $relativePath"
        }

        $sourceHash = (
            Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256
        ).Hash

        $targetHash = (
            Get-FileHash -LiteralPath $targetFile -Algorithm SHA256
        ).Hash

        if ($sourceHash -ne $targetHash) {
            throw "File hash differs: $relativePath"
        }
    }
}

function Get-JunctionTarget {
    param(
        [Parameter(Mandatory = $true)]
        $Item
    )

    $targetProperty = $Item.PSObject.Properties['Target']

    if (
        $null -ne $targetProperty -and
        $null -ne $targetProperty.Value
    ) {
        return @($targetProperty.Value)[0]
    }

    $linkTargetProperty = $Item.PSObject.Properties['LinkTarget']

    if (
        $null -ne $linkTargetProperty -and
        $null -ne $linkTargetProperty.Value
    ) {
        return @($linkTargetProperty.Value)[0]
    }

    return $null
}

function Assert-SourceJunction {
    Assert-PathRelationship

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Junction path does not exist: $Source"
    }

    $sourceItem = Get-Item -LiteralPath $Source -Force

    if (-not (Test-ReparsePoint -Item $sourceItem)) {
        throw "Source is a physical directory, not a junction: $Source"
    }

    $actualTarget = Get-JunctionTarget -Item $sourceItem

    if ([string]::IsNullOrWhiteSpace($actualTarget)) {
        throw 'Cannot determine the junction target.'
    }

    $actualTarget = Convert-ToNormalizedPath $actualTarget

    if (-not $actualTarget.Equals(
        $Target,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw @"
Junction points to an unexpected directory.

Actual:   $actualTarget
Expected: $Target
"@
    }

    return $actualTarget
}

try {
    $Source = Convert-ToNormalizedPath $Source
    $Target = Convert-ToNormalizedPath $Target

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object `
        -TypeName Security.Principal.WindowsPrincipal `
        -ArgumentList $identity

    $isElevated = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if ($isElevated) {
        throw @'
Run this script from a normal, non-elevated PowerShell session.

This prevents elevated-only target permissions that later break normal apps.
'@
    }

    switch ($Action) {
        'Audit' {
            Assert-PhysicalSource
            Assert-TargetEmpty

            foreach ($relativePath in $HashRelativePath) {
                Assert-SafeRelativeHashPath -RelativePath $relativePath

                $sourceHashFile = Join-Path $Source $relativePath

                if (-not (Test-Path -LiteralPath $sourceHashFile -PathType Leaf)) {
                    throw "Hash source file does not exist: $relativePath"
                }
            }

            $sourceStats = Get-DirectoryStatistics -Path $Source
            $targetDrive = Get-DriveInfoForPath -Path $Target
            $targetFreeBytes = [int64]$targetDrive.AvailableFreeSpace

            if ($targetFreeBytes -lt ($sourceStats.Bytes + 1GB)) {
                throw 'Target volume needs the source size plus at least 1 GB free.'
            }

            $matchingProcesses = @(Get-MatchingProcesses)

            [pscustomobject]@{
                Result                 = 'AUDIT PASSED'
                Source                 = $Source
                Target                 = $Target
                SourceFiles            = $sourceStats.Files
                SourceSizeGB           = [math]::Round($sourceStats.Bytes / 1GB, 2)
                TargetFreeGB           = [math]::Round($targetFreeBytes / 1GB, 2)
                ProcessChecks          = if ($ProcessName.Count -gt 0) {
                    $ProcessName -join ', '
                } else {
                    '(manual confirmation only)'
                }
                MatchingProcessesFound = $matchingProcesses.Count
                HashChecks             = if ($HashRelativePath.Count -gt 0) {
                    $HashRelativePath -join ', '
                } else {
                    '(none)'
                }
                NextAction             = 'Close users of Source, then run Copy.'
            }
        }

        'Copy' {
            Assert-PhysicalSource
            Assert-TargetEmpty
            Confirm-SourceUnused

            if (-not (Test-Path -LiteralPath $Target)) {
                New-Item `
                    -ItemType Directory `
                    -Path $Target `
                    -Force |
                    Out-Null
            }

            $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'

            & $robocopy $Source $Target `
                /E `
                /COPY:DAT `
                /DCOPY:DAT `
                /XJ `
                /R:2 `
                /W:1

            $copyExitCode = $LASTEXITCODE

            if ($copyExitCode -ge 8) {
                throw @"
Robocopy failed with exit code $copyExitCode.
Source was not moved or deleted. Target may contain a partial copy.
"@
            }

            $matchingProcesses = @(Get-MatchingProcesses)

            if ($matchingProcesses.Count -gt 0) {
                throw 'A checked process started during Copy. Do not run Switch.'
            }

            Invoke-ExactCopyVerification

            [pscustomobject]@{
                Result           = 'COPY PASSED'
                SourceUnchanged  = $Source
                CopiedTo         = $Target
                RobocopyExitCode = $copyExitCode
                NextAction       = 'Run Switch while Source remains unused.'
            }
        }

        'Switch' {
            Assert-PhysicalSource

            if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
                throw 'Target does not exist. Run Copy first.'
            }

            Confirm-SourceUnused
            Invoke-ExactCopyVerification

            Write-Host ''
            Write-Host "Source: $Source"
            Write-Host "Target: $Target"
            Write-Host ''
            Write-Host 'Source will be renamed to a timestamped backup.'
            Write-Host 'No source or target data will be deleted.'
            Write-Host ''

            $confirmation = Read-Host 'Type uppercase SWITCH to continue'

            if ($confirmation -cne 'SWITCH') {
                throw 'Switch cancelled.'
            }

            $sourceParent = Split-Path -Path $Source -Parent
            $sourceName = Split-Path -Path $Source -Leaf
            $backupName = "$sourceName.backup-$(
                Get-Date -Format 'yyyyMMdd-HHmmss'
            )"
            $backupPath = Join-Path $sourceParent $backupName

            if (Test-Path -LiteralPath $backupPath) {
                throw "Backup path already exists: $backupPath"
            }

            $sourceRenamed = $false

            try {
                Rename-Item `
                    -LiteralPath $Source `
                    -NewName $backupName

                $sourceRenamed = $true

                New-Item `
                    -ItemType Junction `
                    -Path $Source `
                    -Target $Target |
                    Out-Null
            }
            catch {
                if (
                    $sourceRenamed -and
                    -not (Test-Path -LiteralPath $Source) -and
                    (Test-Path -LiteralPath $backupPath)
                ) {
                    Rename-Item `
                        -LiteralPath $backupPath `
                        -NewName $sourceName
                }

                throw
            }

            $verifiedTarget = Assert-SourceJunction

            [pscustomobject]@{
                Result         = 'SWITCH PASSED'
                Junction       = $Source
                JunctionTarget = $verifiedTarget
                Backup         = $backupPath
                NextAction     = 'Run Status, then test the application.'
            }

            Write-Host ''
            Write-Host 'Keep the Backup path until every test passes.'
        }

        'Status' {
            Assert-PathRelationship

            $sourceState = 'Missing'
            $junctionTarget = $null

            if (Test-Path -LiteralPath $Source) {
                $sourceItem = Get-Item -LiteralPath $Source -Force

                if (Test-ReparsePoint -Item $sourceItem) {
                    $sourceState = 'Junction'
                    $junctionTarget = Assert-SourceJunction
                }
                else {
                    $sourceState = 'PhysicalDirectory'
                }
            }

            $sourceParent = Split-Path -Path $Source -Parent
            $sourceName = Split-Path -Path $Source -Leaf
            $backupDirectories = @(
                Get-ChildItem `
                    -LiteralPath $sourceParent `
                    -Directory `
                    -Filter "$sourceName.backup-*" `
                    -ErrorAction SilentlyContinue
            )

            [pscustomobject]@{
                Source         = $Source
                SourceState    = $sourceState
                JunctionTarget = $junctionTarget
                ExpectedTarget = $Target
                TargetExists   = Test-Path `
                    -LiteralPath $Target `
                    -PathType Container
                BackupCount    = $backupDirectories.Count
                RunningMatches = @(Get-MatchingProcesses).Count
            }

            if ($backupDirectories.Count -gt 0) {
                Write-Host ''
                Write-Host 'Backup directories:'

                $backupDirectories |
                    Select-Object FullName, LastWriteTime |
                    Format-Table -AutoSize
            }
        }

        'Rollback' {
            Assert-SourceJunction | Out-Null
            Confirm-SourceUnused

            $sourceParent = Split-Path -Path $Source -Parent
            $sourceName = Split-Path -Path $Source -Leaf

            if ([string]::IsNullOrWhiteSpace($Backup)) {
                $backupCandidates = @(
                    Get-ChildItem `
                        -LiteralPath $sourceParent `
                        -Directory `
                        -Filter "$sourceName.backup-*"
                )

                if ($backupCandidates.Count -ne 1) {
                    $backupCandidates |
                        Select-Object FullName, LastWriteTime |
                        Format-Table -AutoSize

                    throw @"
Cannot select exactly one backup.
Pass the exact path with -Backup 'C:\...\name.backup-yyyyMMdd-HHmmss'.
"@
                }

                $Backup = $backupCandidates[0].FullName
            }

            $Backup = Convert-ToNormalizedPath $Backup
            $backupParent = Split-Path -Path $Backup -Parent

            if (-not $backupParent.Equals(
                $sourceParent,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Backup is not in the expected source parent directory.'
            }

            $backupLeaf = Split-Path -Path $Backup -Leaf
            $escapedSourceName = [regex]::Escape($sourceName)

            if ($backupLeaf -notmatch "^$escapedSourceName\.backup-\d{8}-\d{6}$") {
                throw 'Backup name does not match the script naming convention.'
            }

            if (-not (Test-Path -LiteralPath $Backup -PathType Container)) {
                throw "Backup does not exist: $Backup"
            }

            $backupItem = Get-Item -LiteralPath $Backup -Force

            if (Test-ReparsePoint -Item $backupItem) {
                throw 'Backup must be a physical directory.'
            }

            Write-Host ''
            Write-Host "Junction: $Source"
            Write-Host "Target:   $Target"
            Write-Host "Backup:   $Backup"
            Write-Host ''
            Write-Host 'Target will not be deleted.'

            $confirmation = Read-Host 'Type uppercase ROLLBACK to continue'

            if ($confirmation -cne 'ROLLBACK') {
                throw 'Rollback cancelled.'
            }

            # Source was strictly verified as the expected junction above.
            # Do not add -Recurse here.
            Remove-Item -LiteralPath $Source -Force

            if (Test-Path -LiteralPath $Source) {
                throw 'The junction could not be removed. Rollback stopped.'
            }

            Rename-Item `
                -LiteralPath $Backup `
                -NewName $sourceName

            Assert-PhysicalSource

            [pscustomobject]@{
                Result         = 'ROLLBACK PASSED'
                RestoredSource = $Source
                TargetRetained = $Target
            }
        }
    }
}
finally {
    $ErrorActionPreference = $previousErrorAction
}
