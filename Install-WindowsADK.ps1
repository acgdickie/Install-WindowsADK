<#
.SYNOPSIS
    Downloads and installs the Windows Assessment and Deployment Kit (ADK), and optionally the WinPE add-on.

.DESCRIPTION
    Default mode: downloads the official installer (adksetup.exe) from Microsoft, checks its digital
    signature, and installs it silently.
    -UseWinget mode: installs the ADK with winget instead.

    The installer itself is never allowed to restart Windows (/norestart is always passed).
    After the install, this script decides:
      * A restart is needed     -> Windows restarts after a countdown. Use -SuppressReboot to stop this.
      * No restart is needed    -> no restart. Use -ForceReboot to restart anyway.
    To cancel a countdown, run: shutdown /a

    If the same or a newer version is already installed, that part is skipped.
    If an older version is installed, it is removed first (the installer cannot install over it),
    then the new version is installed. If an earlier install still waits for a restart, that
    counts as "a restart is needed".

    Exit codes:
      0      Success. No restart needed.
      3010   Success. A restart is needed, but it did not happen (-SuppressReboot, you said No, or
             the restart could not be scheduled).
      1641   Success. A restart was started (by this script, or one was already scheduled).
      1602   You said No to an install question (-Confirm).
      other  Failure. The installer's or winget's error code (1 for errors in this script).

.PARAMETER UseWinget
    Install with winget instead of the direct Microsoft download.
    Note (October 2026): winget's ADK packages are behind Microsoft's download page. Its only
    10.1.26100 version (2454) can no longer install, so -UseWinget stops with an explanation unless
    you pick a version with -WingetVersion.

.PARAMETER IncludeWinPE
    Also install the Windows PE add-on (needed to make WinPE boot media). Its version must match the
    installed ADK.

.PARAMETER Features
    ADK feature IDs to install, for example OptionId.DeploymentTools,OptionId.UserStateMigrationTool.
    Separate them with commas. To separate them with spaces, put the whole list in quotes.
    Use + for all features. If you leave this out, the installer's own default features are installed.
    This has no effect on an ADK that is already installed.

.PARAMETER InstallPath
    Install folder. Default: C:\Program Files (x86)\Windows Kits\10

.PARAMETER SuppressReboot
    Never restart Windows, even when the install needs it. The script then exits with 3010.

.PARAMETER ForceReboot
    Restart Windows after a successful install, even when the install does not need it.

.PARAMETER RebootDelaySeconds
    Seconds to wait before a restart (0 to 600). Default: 60. Open programs are closed when the time is up.

.PARAMETER WingetVersion
    With -UseWinget: the exact package version to install, for example 10.1.28000.1.
    Default: the newest winget version on the 10.1.26100 line that can still install (with a matching
    WinPE add-on when -IncludeWinPE is set). 10.1.28000.1 installs, but Microsoft made it for
    Windows 11 26H1 Arm64 only, and winget has no WinPE add-on for it.

.PARAMETER AdkUrl
    Download link for adksetup.exe. Default: Microsoft's link for the current ADK.

.PARAMETER WinPEUrl
    Download link for adkwinpesetup.exe. Default: Microsoft's link for the matching WinPE add-on.

.EXAMPLE
    .\Install-WindowsADK.ps1
    Downloads and installs the ADK. Restarts Windows only if the install needs it.

.EXAMPLE
    .\Install-WindowsADK.ps1 -IncludeWinPE -SuppressReboot
    Installs the ADK and the WinPE add-on. Never restarts Windows.

.EXAMPLE
    .\Install-WindowsADK.ps1 -ForceReboot -RebootDelaySeconds 300
    Installs the ADK, then restarts Windows after 5 minutes, even if no restart is needed.

.EXAMPLE
    .\Install-WindowsADK.ps1 -UseWinget -WingetVersion 10.1.28000.1 -SuppressReboot
    Installs ADK 10.1.28000.1 with winget. Never restarts Windows.
    Warning: Microsoft made 10.1.28000.1 for Windows 11 26H1 on Arm64 PCs only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WindowsADK.ps1 -Features "OptionId.DeploymentTools,OptionId.UserStateMigrationTool" -WhatIf
    Shows what would happen, without changing anything.

.NOTES
    Made in response to Veeam KB4885 (https://www.veeam.com/kb4885): Veeam Recovery Media built from
    WinRE fails to restore after Microsoft's June 2026 update. Veeam's workaround is to build the media
    with the Windows ADK and the WinPE add-on, which this script installs (use -IncludeWinPE).
    Project page: https://github.com/acgdickie/Install-WindowsADK

    Run as Administrator. Works in Windows PowerShell 5.1 and PowerShell 7.
    From another program (for example Intune), start it with -File so the exit code is kept:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WindowsADK.ps1
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'AutoReboot')]
param(
    [switch]$UseWinget,

    [switch]$IncludeWinPE,

    [string[]]$Features,

    [ValidateScript({ [System.IO.Path]::IsPathRooted($_) })]
    [string]$InstallPath,

    [Parameter(Mandatory, ParameterSetName = 'SuppressReboot')]
    [switch]$SuppressReboot,

    [Parameter(Mandatory, ParameterSetName = 'ForceReboot')]
    [switch]$ForceReboot,

    [Parameter(ParameterSetName = 'AutoReboot')]
    [Parameter(ParameterSetName = 'ForceReboot')]
    [ValidateRange(0, 600)]
    [int]$RebootDelaySeconds = 60,

    [ValidatePattern('^\d+(\.\d+){1,3}$')]
    [string]$WingetVersion,

    [ValidatePattern('^https://')]
    [string]$AdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980',

    [ValidatePattern('^https://')]
    [string]$WinPEUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'
)

#region Decision logic (unit tested in Install-WindowsADK.Tests.ps1)

function Get-KitDefinition {
    # Fixed facts about each kit. The upgrade codes stay the same across ADK versions.
    param([Parameter(Mandatory)][ValidateSet('ADK', 'WinPE')][string]$Kit)

    switch ($Kit) {
        'ADK' {
            [pscustomobject]@{
                Name        = 'Windows ADK'
                FileName    = 'adksetup.exe'
                WingetId    = 'Microsoft.WindowsADK'
                UpgradeCode = '{80114C7E-A1FE-8C0E-E86C-38C5486AF51E}'
                NamePattern = '^Windows Assessment and Deployment Kit( - Windows 10)?$'
            }
        }
        'WinPE' {
            [pscustomobject]@{
                Name        = 'Windows PE add-on'
                FileName    = 'adkwinpesetup.exe'
                WingetId    = 'Microsoft.WindowsADK.WinPEAddon'
                UpgradeCode = '{C65E68FC-10D3-CB37-5B36-4880129E14E8}'
                NamePattern = '^Windows Assessment and Deployment Kit Windows Preinstallation Environment Add-ons( - Windows 10)?$'
            }
        }
    }
}

function ConvertTo-Version {
    # Turns '10.1.26100.9457' into a [version]. Anything unreadable becomes 0.0.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $parsed = $null
    if ($Text -and [version]::TryParse($Text.Trim(), [ref]$parsed)) { return $parsed }
    [version]'0.0'
}

function ConvertTo-QuotedArgument {
    # Wraps a value in double quotes by the Windows command-line rules, so the program receives it
    # as one argument. Embedded quotes and trailing backslashes are escaped.
    param([AllowEmptyString()][string]$Value)

    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    '"' + $escaped + '"'
}

function Get-KitUninstallCommand {
    # Turns a kit's registered quiet uninstall command into a program path and arguments, and adds
    # /norestart and a log. (The registered command has only /quiet, and then the uninstaller can
    # restart Windows by itself.)
    param(
        [AllowNull()][AllowEmptyString()][string]$QuietUninstallString,
        [Parameter(Mandatory)][string]$LogFile
    )

    if (-not $QuietUninstallString) { return $null }
    if ($QuietUninstallString -notmatch '^\s*"([^"]+)"\s*(.*)$' -and $QuietUninstallString -notmatch '^\s*(\S+)\s*(.*)$') { return $null }
    $filePath = $Matches[1]
    $switches = @($Matches[2] -split '\s+' | Where-Object { $_ })
    if ($switches -notcontains '/norestart') { $switches += '/norestart' }
    [pscustomobject]@{
        FilePath  = $filePath
        Arguments = (@($switches) + ('/log ' + (ConvertTo-QuotedArgument $LogFile))) -join ' '
    }
}

function ConvertTo-FeatureList {
    # Splits feature IDs given as 'A,B', 'A B' or @('A','B') and checks each one.
    # ('powershell.exe -File' passes '-Features A,B' as one string.)
    param([AllowEmptyCollection()][string[]]$Features)

    foreach ($item in @($Features -split '[,\s]+' | Where-Object { $_ })) {
        if ($item -notmatch '^(\+|OptionId\.[A-Za-z]+\+?)$') {
            throw "'$item' is not a valid feature ID. Use names like OptionId.DeploymentTools, or + for all features."
        }
        $item
    }
}

function Get-BootstrapperArguments {
    # Command line for adksetup.exe / adkwinpesetup.exe. /norestart is always included: without it,
    # /quiet lets the installer restart Windows by itself with no warning.
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [string[]]$Features,
        [string]$InstallPath
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.AddRange([string[]]@('/quiet', '/norestart', '/ceip off'))
    if ($Features) { $parts.Add('/features ' + ($Features -join ' ')) }
    if ($InstallPath) {
        $path = $InstallPath.TrimEnd('\')
        if ($path -match '^[A-Za-z]:$') { $path += '\' }
        $parts.Add('/installpath ' + (ConvertTo-QuotedArgument $path))
    }
    $parts.Add('/log ' + (ConvertTo-QuotedArgument $LogFile))
    $parts -join ' '
}

function New-InstallResult {
    param([bool]$Succeeded, [bool]$RebootRequired, [bool]$AlreadyInstalled = $false, [int]$ExitCode, [string]$Message)

    [pscustomobject]@{
        Succeeded        = $Succeeded
        RebootRequired   = $RebootRequired
        AlreadyInstalled = $AlreadyInstalled
        ExitCode         = $ExitCode
        Message          = $Message
    }
}

function ConvertFrom-BootstrapperExitCode {
    # Meaning of the exit codes of adksetup.exe / adkwinpesetup.exe (WiX Burn bundles).
    param([Parameter(Mandatory)][int]$ExitCode)

    $hex = '0x{0:X8}' -f $ExitCode
    switch ($ExitCode) {
        0     { return New-InstallResult $true  $false -ExitCode $ExitCode -Message 'Installed.' }
        3010  { return New-InstallResult $true  $true  -ExitCode $ExitCode -Message 'Installed. A restart is needed to finish.' }
        1641  { return New-InstallResult $true  $true  -ExitCode $ExitCode -Message 'Installed. The installer asked for a restart.' }
        1618  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'Another installation is running. Wait for it to finish, then try again.' }
        2007  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'A restart from an earlier ADK install is still pending. Restart Windows, then try again.' }
        1000  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The installer did not accept the command line. Check the -Features names.' }
        1001  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The installer did not accept the features or install path. If the ADK is already installed in another folder, do not use -InstallPath.' }
        2001  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'A newer version is already installed. The installer cannot downgrade.' }
        2004  { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The installer could not download its files. Check the internet connection.' }
        15605 { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The installer could not download its files. Check the internet connection.' }
        -2147023294 { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The installation was cancelled.' }
        -2146889721 { return New-InstallResult $false $false -ExitCode $ExitCode -Message 'The files the installer downloaded failed their hash check (0x80091007). This happens when Microsoft has replaced the files of an older ADK version. Install the newest version instead: run this script without -UseWinget, -WingetVersion, -AdkUrl and -WinPEUrl.' }
    }
    New-InstallResult $false $false -ExitCode $ExitCode -Message "The installer failed with exit code $ExitCode ($hex). See the log file."
}

function Get-BurnLogExitCode {
    # Reads the installer's own exit code from the last 'i007: Exit code: 0x...' line of its log.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $line = Select-String -LiteralPath $Path -Pattern 'i007: Exit code: 0x([0-9A-Fa-f]{1,8})\b' | Select-Object -Last 1
    if (-not $line) { return $null }
    [Convert]::ToInt32($line.Matches[0].Groups[1].Value, 16)
}

function Resolve-WingetResult {
    # winget runs the ADK as a plain 'exe' installer and knows none of its reboot codes, so an
    # installer 3010 comes back as SHELLEXEC_INSTALL_FAILED. The installer log decides in that case.
    param(
        [Parameter(Mandatory)][int]$WingetExitCode,
        [Nullable[int]]$InstallerExitCode
    )

    $shellExecFailed = -1978335226  # 0x8A150006 APPINSTALLER_CLI_ERROR_SHELLEXEC_INSTALL_FAILED
    if ($null -ne $InstallerExitCode -and ($WingetExitCode -eq 0 -or $WingetExitCode -eq $shellExecFailed)) {
        return ConvertFrom-BootstrapperExitCode -ExitCode $InstallerExitCode
    }

    $hex = '0x{0:X8}' -f $WingetExitCode
    switch ($WingetExitCode) {
        0           { return New-InstallResult $true  $false -ExitCode 0 -Message 'Installed.' }
        -1978334967 { return New-InstallResult $true  $true  -ExitCode $WingetExitCode -Message 'Installed. winget says a restart is needed to finish.' }   # 0x8A150109
        -1978334965 { return New-InstallResult $true  $true  -ExitCode $WingetExitCode -Message 'Installed. winget says the installer asked for a restart.' } # 0x8A15010B
        -1978335189 { return New-InstallResult $true  $false $true -ExitCode $WingetExitCode -Message 'Already installed. No newer version applies.' }      # 0x8A15002B
        -1978335135 { return New-InstallResult $true  $false $true -ExitCode $WingetExitCode -Message 'Already installed.' }                              # 0x8A150061
        -1978334963 { return New-InstallResult $true  $false $true -ExitCode $WingetExitCode -Message 'Already installed.' }                              # 0x8A15010D
        -1978335212 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'winget did not find the package.' }                      # 0x8A150014
        -1978335209 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'winget did not find that package version.' }             # 0x8A150017
        -1978334966 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'Windows must restart before this install can run.' }   # 0x8A15010A
        -1978334974 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'Another installation is running. Try again later.' }    # 0x8A150102
        -1978335224 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'winget could not download the installer.' }            # 0x8A150008
        -1978335215 { return New-InstallResult $false $false -ExitCode $WingetExitCode -Message 'The downloaded installer did not match the expected hash.' } # 0x8A150011
    }
    New-InstallResult $false $false -ExitCode $WingetExitCode -Message "winget failed with exit code $WingetExitCode ($hex)."
}

function ConvertFrom-WingetVersionList {
    # Picks the version lines out of 'winget show --versions' output.
    param([AllowEmptyCollection()][string[]]$Text)

    foreach ($line in $Text) {
        if ($line -match '^\s*(\d+(?:\.\d+){1,3})\s*$') { $Matches[1] }
    }
}

function Select-WingetKitVersion {
    # Newest ADK version on the release line. With -IncludeWinPE, only versions that also have a
    # WinPE add-on of the same version count, so the two always match. -ExcludeVersion lists
    # versions that are known not to install.
    param(
        [AllowEmptyCollection()][string[]]$AdkVersions,
        [AllowEmptyCollection()][string[]]$WinPEVersions,
        [Parameter(Mandatory)][string]$ReleaseLine,
        [switch]$IncludeWinPE,
        [string[]]$ExcludeVersion
    )

    $candidates = @($AdkVersions | Where-Object { $_ -like "$ReleaseLine.*" -and @($ExcludeVersion) -notcontains $_ })
    if ($IncludeWinPE) {
        $candidates = @($candidates | Where-Object { @($WinPEVersions) -contains $_ })
    }
    $candidates | Sort-Object { ConvertTo-Version $_ } -Descending | Select-Object -First 1
}

function Select-KitEntry {
    # Finds the newest finished install of a kit in the registry uninstall entries. Matches the
    # bundle upgrade code first, then the exact display name. (A plain 'Windows Assessment and
    # Deployment Kit*' wildcard would also match the WinPE add-on.)
    # Burn writes the entry when an install starts and sets Installed=1 only when it finishes.
    # The result has RebootPending = $true when Burn's '<BundleId>.RebootRequired' key exists,
    # which means an earlier install of this kit still waits for a restart.
    param(
        [AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][ValidateSet('ADK', 'WinPE')][string]$Kit
    )

    $def = Get-KitDefinition $Kit
    $entry = $Entries |
        Where-Object {
            $_.DisplayVersion -and "$($_.Installed)" -eq '1' -and (
                (@($_.BundleUpgradeCode) -contains $def.UpgradeCode) -or
                ($_.DisplayName -match $def.NamePattern))
        } |
        Sort-Object { ConvertTo-Version $_.DisplayVersion } -Descending |
        Select-Object -First 1
    if (-not $entry) { return }

    $rebootKey = "$($entry.PSChildName).RebootRequired"
    $pending = @($Entries | Where-Object { $_.PSChildName -eq $rebootKey }).Count -gt 0
    $entry | Select-Object *, @{ Name = 'RebootPending'; Expression = { $pending } }
}

function Resolve-RebootPlan {
    # Decides what happens after the install and which exit code the script returns.
    #   Reboot     -> the script restarts Windows (exit 1641, "restart started").
    #   Suppressed -> a reboot is due but -SuppressReboot stops it (exit 3010, "restart required").
    #   None       -> no restart (exit 0, or the failure code when the install failed).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Succeeded,
        [Parameter(Mandatory)][bool]$RebootRequired,
        [switch]$SuppressReboot,
        [switch]$ForceReboot,
        [int]$FailureExitCode = 1
    )

    if (-not $Succeeded) {
        $code = if ($FailureExitCode -ne 0) { $FailureExitCode } else { 1 }
        return [pscustomobject]@{ Action = 'None'; ExitCode = $code }
    }
    if ($SuppressReboot) {
        if ($RebootRequired) { return [pscustomobject]@{ Action = 'Suppressed'; ExitCode = 3010 } }
        return [pscustomobject]@{ Action = 'None'; ExitCode = 0 }
    }
    if ($ForceReboot -or $RebootRequired) {
        return [pscustomobject]@{ Action = 'Reboot'; ExitCode = 1641 }
    }
    [pscustomobject]@{ Action = 'None'; ExitCode = 0 }
}

function Test-KitInstaller {
    # Checks that an installer (or uninstaller) is signed by Microsoft and is the kit we expect.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('ADK', 'WinPE')][string]$Kit
    )

    $fail = { param($why) [pscustomobject]@{ IsTrusted = $false; Reason = $why; Version = $null } }

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { return & $fail "The digital signature is not valid ($($sig.Status))." }
    $subject = $sig.SignerCertificate.Subject
    if ($subject -notmatch '^CN=Microsoft Corporation,' -or $subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        return & $fail "The file is signed by '$subject', not by Microsoft Corporation."
    }
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    $def = Get-KitDefinition $Kit
    if ($info.ProductName -notmatch $def.NamePattern) {
        return & $fail "The file is '$($info.ProductName)', not the $($def.Name)."
    }
    $version = if ($info.FileVersion -match '^\d+(\.\d+){1,3}') { ConvertTo-Version $Matches[0] } else { [version]'0.0' }
    [pscustomobject]@{ IsTrusted = $true; Reason = $null; Version = $version }
}

#endregion

#region System helpers (exercised by running the script)

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UninstallEntry {
    # Every uninstall entry from both the 64-bit and the 32-bit registry views. The ADK installer is
    # 32-bit, so on 64-bit Windows its entries are in the 32-bit view.
    foreach ($view in 'Registry64', 'Registry32') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            try {
                foreach ($name in $root.GetSubKeyNames()) {
                    $key = $root.OpenSubKey($name)
                    if (-not $key) { continue }
                    try {
                        [pscustomobject]@{
                            PSChildName       = $name
                            DisplayName       = $key.GetValue('DisplayName')
                            DisplayVersion    = $key.GetValue('DisplayVersion')
                            BundleUpgradeCode = $key.GetValue('BundleUpgradeCode')
                            Installed         = $key.GetValue('Installed')
                            QuietUninstallString = $key.GetValue('QuietUninstallString')
                        }
                    }
                    finally { $key.Close() }
                }
            }
            finally { $root.Close() }
        }
        finally { $base.Close() }
    }
}

function Get-InstalledKit {
    param([Parameter(Mandatory)][ValidateSet('ADK', 'WinPE')][string]$Kit)

    Select-KitEntry -Entries @(Get-UninstallEntry) -Kit $Kit
}

function Get-KitsRoot {
    # Install root of the Windows Kits, for example 'C:\Program Files (x86)\Windows Kits\10\'.
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, 'Registry32')
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
        if ($key) { try { return $key.GetValue('KitsRoot10') } finally { $key.Close() } }
    }
    finally { $base.Close() }
}

function Get-PendingRebootReason {
    # Restart flags Windows already had before this script ran. Shown as a warning only.
    # (PendingFileRenameOperations is left out: it is almost never empty on a healthy PC.)
    # The 64-bit registry view is used, so this also works from 32-bit PowerShell.
    $checks = [ordered]@{
        'Windows servicing' = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update'    = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, 'Registry64')
    try {
        foreach ($check in $checks.GetEnumerator()) {
            $key = $base.OpenSubKey($check.Value)
            if ($key) { $key.Close(); $check.Key }
        }
    }
    finally { $base.Close() }
}

function New-RunDirectory {
    # A new folder for this run that only SYSTEM and Administrators can change, so nobody can swap
    # the installer between the signature check and the start. The folder is created with its
    # locked-down permissions in one step, then checked.
    param([Parameter(Mandatory)][string]$Parent)

    $admins = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }

    $null = [System.IO.Directory]::CreateDirectory($Parent)
    $name = 'WindowsADK_{0:yyyyMMdd-HHmmss}_{1}' -f (Get-Date), [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $Parent $name
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $null = [System.IO.FileSystemAclExtensions]::Create([System.IO.DirectoryInfo]::new($path), $acl)
    }
    else {
        $null = [System.IO.Directory]::CreateDirectory($path, $acl)
    }

    # If someone else made this folder first, it has their owner or holds their files. Stop then.
    $owner = (Get-Acl -LiteralPath $path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin 'S-1-5-32-544', 'S-1-5-18' -or @(Get-ChildItem -LiteralPath $path -Force).Count -gt 0) {
        throw "The work folder '$path' was changed by someone else. Nothing was installed."
    }
    $path
}

function Save-KitInstaller {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination)

    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'  # the progress bar makes Windows PowerShell 5.1 downloads very slow
    try {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            # Windows PowerShell 5.1: make sure TLS 1.2 is allowed, without turning off the OS default.
            $protocols = [Net.ServicePointManager]::SecurityProtocol
            if ([int]$protocols -ne 0 -and -not ($protocols -band [Net.SecurityProtocolType]::Tls12)) {
                [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Net.SecurityProtocolType]::Tls12
            }
        }
        for ($try = 1; $try -le 3; $try++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
                return
            }
            catch {
                if ($try -eq 3) { throw }
                Write-Warning "Download failed (try $try of 3): $($_.Exception.Message) Trying again."
                Start-Sleep -Seconds (5 * $try)
            }
        }
    }
    finally { $ProgressPreference = $oldProgress }
}

function Start-ProcessAndWait {
    # Starts a program, waits for it (not for programs it leaves running), and returns its exit code.
    # Process.Start is used instead of Start-Process, which reads [ ] in a path as wildcards and
    # could start a different file than the one that was checked.
    # -ReleaseAfterStart: a lock on the program file, released once the program is running.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [IDisposable]$ReleaseAfterStart
    )

    Write-Verbose "Running: `"$FilePath`" $Arguments"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $startInfo.UseShellExecute = $false
    try { $process = [System.Diagnostics.Process]::Start($startInfo) }
    finally { if ($ReleaseAfterStart) { $ReleaseAfterStart.Dispose() } }
    try {
        $process.WaitForExit()
        $process.ExitCode
    }
    finally { $process.Dispose() }
}

function Find-Winget {
    $command = Get-Command -Name winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    # winget is not on PATH (for example when running as SYSTEM). Look in the App Installer package
    # folder. ProgramW6432 is the real Program Files folder, also from 32-bit PowerShell.
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    Get-ChildItem -Path (Join-Path $programFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'winget.exe') } |
        Sort-Object { ConvertTo-Version ($_.Name -split '_')[1] } -Descending |
        Select-Object -First 1 |
        ForEach-Object { Join-Path $_.FullName 'winget.exe' }
}

function Get-WingetPackageVersion {
    param([Parameter(Mandatory)][string]$Winget, [Parameter(Mandatory)][string]$PackageId)

    $output = & $Winget show --id $PackageId --exact --source winget --versions --accept-source-agreements --disable-interactivity 2>&1
    @(ConvertFrom-WingetVersionList -Text @($output | ForEach-Object { "$_" }))
}

function Write-Step {
    param([string]$Message)
    Write-Host "[ADK] $Message"
}

function Exit-Script {
    param([string]$Message, [int]$ExitCode = 1)
    Write-Host "[ADK] ERROR: $Message" -ForegroundColor Red
    exit $ExitCode
}

function Remove-OlderKit {
    # The ADK installers refuse to install over an older version ("MSI replacement servicing is
    # not supported", exit 2008). So the older version is removed first, without a restart.
    # Returns an install result: Succeeded, RebootRequired, ExitCode, Message.
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('ADK', 'WinPE')][string]$Kit,
        [Parameter(Mandatory)][string]$LogFile
    )

    $def = Get-KitDefinition $Kit
    $command = Get-KitUninstallCommand -QuietUninstallString $Entry.QuietUninstallString -LogFile $LogFile
    if (-not $command -or -not (Test-Path -LiteralPath $command.FilePath -PathType Leaf)) {
        return New-InstallResult $false $false -ExitCode 1 -Message "Could not find the uninstaller of $($def.Name) $($Entry.DisplayVersion). Remove it in Settings > Apps, then run again."
    }
    $lock = [System.IO.File]::Open($command.FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $check = Test-KitInstaller -Path $command.FilePath -Kit $Kit
        if (-not $check.IsTrusted) {
            return New-InstallResult $false $false -ExitCode 1 -Message "The uninstaller of $($def.Name) $($Entry.DisplayVersion) failed the safety check: $($check.Reason)"
        }
        Write-Step "Removing the older $($def.Name) $($Entry.DisplayVersion) first. The installer cannot install over it..."
        $code = Start-ProcessAndWait -FilePath $command.FilePath -Arguments $command.Arguments -ReleaseAfterStart $lock
    }
    finally { $lock.Dispose() }

    $result = ConvertFrom-BootstrapperExitCode -ExitCode $code
    if (-not $result.Succeeded) {
        $result.Message = "Could not remove the older $($def.Name) $($Entry.DisplayVersion). $($result.Message)"
    }
    $result
}

function Set-AlreadyInstalled {
    # Marks a result row as "already installed". A restart still pending from the earlier install
    # counts as "a restart is needed", so the reboot rules still apply.
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Entry)

    $Row.Version = $Entry.DisplayVersion
    $Row.Succeeded = $true
    $Row.Result = "Already installed ($($Entry.DisplayVersion))."
    if ($Entry.RebootPending) {
        $Row.RebootRequired = $true
        $Row.Result += ' A restart from the earlier install is still pending.'
    }
}

function Set-Declined {
    # A "No" to a -WhatIf / -Confirm question.
    param([Parameter(Mandatory)]$Row)

    if ($WhatIfPreference) {
        $Row.Result = 'Not installed (-WhatIf).'
        $Row.Succeeded = $true
    }
    else {
        $Row.Result = 'Not installed (you said No).'
        $Row.ExitCode = 1602  # ERROR_INSTALL_USEREXIT
    }
}

#endregion

# Dot-sourcing with $env:INSTALL_WINDOWSADK_FUNCTIONS_ONLY = '1' (the tests do this) loads the
# functions above and stops here. Any other way of running the script installs as usual.
if ($MyInvocation.InvocationName -eq '.' -and $env:INSTALL_WINDOWSADK_FUNCTIONS_ONLY -eq '1') { return }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false  # this script checks exit codes itself (PowerShell 7.3+)

# winget versions that can no longer install: Microsoft replaced their download files, so their
# installers fail with 0x80091007 (seen 2026-10-12). Automatic version selection skips them.
$brokenWingetVersions = @('10.1.26100.2454')

$results = [System.Collections.Generic.List[object]]::new()
try {
    # --- Checks before anything changes ---------------------------------------------------------
    if ($UseWinget -and ($PSBoundParameters.ContainsKey('AdkUrl') -or $PSBoundParameters.ContainsKey('WinPEUrl'))) {
        Exit-Script '-AdkUrl and -WinPEUrl work only without -UseWinget.'
    }
    if (-not $UseWinget -and $PSBoundParameters.ContainsKey('WingetVersion')) {
        Exit-Script '-WingetVersion works only with -UseWinget.'
    }
    try { $featureList = @(ConvertTo-FeatureList -Features $Features) }
    catch { Exit-Script $_.Exception.Message }
    if (-not (Test-IsAdministrator)) {
        Exit-Script 'Run this script as Administrator.'
    }
    $running = @(Get-Process -Name adksetup, adkwinpesetup -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Exit-Script 'Another ADK or WinPE setup is already running. Wait for it to finish, then try again.' 1618
    }
    foreach ($reason in @(Get-PendingRebootReason)) {
        Write-Warning "Windows was already waiting for a restart ($reason). If the install fails, restart Windows and try again."
    }

    # The WinPE add-on needs the ADK Deployment Tools.
    if ($IncludeWinPE -and $featureList.Count -gt 0 -and $featureList -notcontains '+' -and $featureList -notcontains 'OptionId.DeploymentTools') {
        Write-Step 'Adding OptionId.DeploymentTools to the features, because the WinPE add-on needs it.'
        $featureList += 'OptionId.DeploymentTools'
    }

    $kits = @('ADK')
    if ($IncludeWinPE) { $kits += 'WinPE' }

    $winget = $null
    $targetVersion = $null
    $peVersions = @()
    if ($UseWinget) {
        $winget = Find-Winget
        if (-not $winget) { Exit-Script 'winget was not found. Install "App Installer" from the Microsoft Store, or run without -UseWinget.' }
        if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') {
            Write-Warning 'winget is not supported when running as SYSTEM. If this fails, run without -UseWinget.'
        }
        Write-Step "Using winget: $winget"

        if ($IncludeWinPE) {
            $peVersions = @(Get-WingetPackageVersion -Winget $winget -PackageId (Get-KitDefinition WinPE).WingetId)
        }
        if ($WingetVersion) {
            $targetVersion = $WingetVersion
            if ($brokenWingetVersions -contains $targetVersion) {
                Write-Warning "winget's ADK $targetVersion can no longer install (Microsoft replaced its files). It will most likely fail."
            }
            if ($IncludeWinPE -and $peVersions -notcontains $targetVersion) {
                Exit-Script "winget has no WinPE add-on $targetVersion (it has: $($peVersions -join ', ')). The ADK and the add-on must match. Nothing was installed."
            }
        }
        else {
            # The 10.1.26100 line is the ADK for x64 Windows 10/11 and Server 2022/2025. winget's
            # newest version (10.1.28000.x) is for Windows 11 26H1 Arm64 only, so it is skipped.
            $releaseLine = '10.1.26100'
            $adkVersions = @(Get-WingetPackageVersion -Winget $winget -PackageId (Get-KitDefinition ADK).WingetId)
            $targetVersion = Select-WingetKitVersion -AdkVersions $adkVersions -WinPEVersions $peVersions -ReleaseLine $releaseLine -IncludeWinPE:$IncludeWinPE -ExcludeVersion $brokenWingetVersions
            if (-not $targetVersion) {
                Exit-Script ("winget has no ADK $releaseLine.x that can still install$(if ($IncludeWinPE) { ' (with a matching WinPE add-on)' }). " +
                    "Its only one, 10.1.26100.2454, fails because Microsoft replaced its files. Nothing was installed.`n" +
                    "        Run without -UseWinget to install the current ADK from Microsoft.`n" +
                    "        Or choose a winget version with -WingetVersion, for example 10.1.28000.1 (made for Windows 11 26H1 Arm64; no WinPE add-on in winget).")
            }
        }
        Write-Step "winget package version: $targetVersion"
    }

    $runDir = $null
    if (-not $WhatIfPreference) {
        # The TEMP folder of the account running the script. Other users cannot change it.
        $runDir = New-RunDirectory -Parent ([System.IO.Path]::GetTempPath())
        Write-Step "Downloads and logs: $runDir"
    }

    # --- Install each kit, one after the other (the installers block each other) -----------------
    foreach ($kit in $kits) {
        $def = Get-KitDefinition $kit
        $row = [pscustomobject]@{ Kit = $def.Name; Version = $null; Result = $null; Succeeded = $false; RebootRequired = $false; ExitCode = 0 }
        $results.Add($row)
        $logFile = if ($runDir) { Join-Path $runDir "$kit-install.log" } else { "$kit-install.log" }

        try {
            $removal = $null
            # The WinPE add-on goes on top of an installed ADK with Deployment Tools, and must match its version.
            $adkVersion = $null
            if ($kit -eq 'WinPE') {
                if (-not $results[0].Succeeded) {
                    $row.Result = 'Skipped, because the ADK step did not succeed.'
                    $row.ExitCode = $results[0].ExitCode
                    continue
                }
                if (-not $WhatIfPreference) {
                    $adk = Get-InstalledKit ADK
                    if (-not $adk) {
                        $row.Result = 'Not installed, because the ADK is not installed.'
                        $row.ExitCode = 1
                        continue
                    }
                    $adkVersion = ConvertTo-Version $adk.DisplayVersion
                    $kitsRoot = Get-KitsRoot
                    if (-not $kitsRoot) { $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }
                    if (-not (Test-Path -LiteralPath (Join-Path $kitsRoot 'Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat'))) {
                        $row.Result = 'Not installed. The installed ADK has no Deployment Tools, which the WinPE add-on needs. Add them (Settings > Apps > Windows Assessment and Deployment Kit > Modify), then run again.'
                        $row.ExitCode = 1
                        continue
                    }
                }
            }

            $installed = Get-InstalledKit $kit
            $installedVersion = if ($installed) { ConvertTo-Version $installed.DisplayVersion } else { $null }
            if ($installed) { Write-Step "$($def.Name) $($installed.DisplayVersion) is installed now." }

            # A WinPE add-on that already matches the installed ADK needs nothing more.
            if ($adkVersion -and $installed -and $installedVersion -eq $adkVersion) {
                Set-AlreadyInstalled -Row $row -Entry $installed
                continue
            }

            $kitFeatures = if ($kit -eq 'ADK') { $featureList } else { @('OptionId.WindowsPreinstallationEnvironment') }
            $installerArgs = Get-BootstrapperArguments -LogFile $logFile -Features $kitFeatures -InstallPath $InstallPath

            if ($UseWinget) {
                $version = if ($adkVersion) { $adkVersion.ToString() } else { $targetVersion }
                $row.Version = $version
                if ($kit -eq 'WinPE' -and $adkVersion -and $peVersions -notcontains $version) {
                    $row.Result = "Not installed. winget has no WinPE add-on $version to match the installed ADK."
                    $row.ExitCode = 1
                    continue
                }
                if ($installed -and $installedVersion -ge (ConvertTo-Version $version)) {
                    Set-AlreadyInstalled -Row $row -Entry $installed
                    continue
                }
                # --force: winget runs the installer directly. Without it, winget may treat this as an
                #   upgrade and first run the old version's own uninstaller, which has no /norestart.
                # --override: replaces winget's own switches ('/quiet' only), so /norestart is always passed.
                $wingetArgs = @(
                    'install', '--id', $def.WingetId, '--exact', '--source', 'winget', '--version', $version,
                    '--silent', '--force', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity',
                    '--override', (ConvertTo-QuotedArgument $installerArgs)
                )
                # Never let winget pull in an ADK as a dependency: it would pick the Arm64-only version.
                if ($kit -eq 'WinPE') { $wingetArgs += '--skip-dependencies' }

                # Ask about both steps first, so -WhatIf shows both and a "No" changes nothing.
                $removeOk = -not $installed -or $PSCmdlet.ShouldProcess("$($def.Name) $($installed.DisplayVersion)", 'Remove the older version')
                $installOk = $PSCmdlet.ShouldProcess("$($def.Name) $version", 'Install with winget')
                if (-not ($removeOk -and $installOk)) {
                    Set-Declined -Row $row
                    continue
                }
                if ($installed) {
                    $removal = Remove-OlderKit -Entry $installed -Kit $kit -LogFile (Join-Path $runDir "$kit-remove.log")
                    if (-not $removal.Succeeded) {
                        $row.Result = $removal.Message
                        $row.ExitCode = $removal.ExitCode
                        continue
                    }
                }
                Write-Step "Installing $($def.Name) $version with winget. This can take several minutes..."
                $wingetCode = Start-ProcessAndWait -FilePath $winget -Arguments ($wingetArgs -join ' ')
                $outcome = Resolve-WingetResult -WingetExitCode $wingetCode -InstallerExitCode (Get-BurnLogExitCode -Path $logFile)
            }
            else {
                $uri = if ($kit -eq 'ADK') { $AdkUrl } else { $WinPEUrl }
                if (-not $PSCmdlet.ShouldProcess("$($def.Name) from $uri", 'Download and install')) {
                    Set-Declined -Row $row
                    continue
                }
                $exe = Join-Path $runDir $def.FileName
                Write-Step "Downloading $($def.FileName) from $uri"
                Save-KitInstaller -Uri $uri -Destination $exe

                # Hold the file open (others may only read it) from the check until the installer runs.
                $lock = [System.IO.File]::Open($exe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                try {
                    $check = Test-KitInstaller -Path $exe -Kit $kit
                    if (-not $check.IsTrusted) {
                        $row.Result = "Not installed. The download failed the safety check: $($check.Reason)"
                        $row.ExitCode = 1
                        continue
                    }
                    $row.Version = $check.Version.ToString()
                    Write-Step "Downloaded $($def.Name) $($row.Version). The Microsoft signature is valid."

                    if ($adkVersion -and $check.Version -ne $adkVersion) {
                        $row.Result = "Not installed. The add-on download is $($row.Version), but the installed ADK is $adkVersion. They must match. Use -WinPEUrl to pick the matching add-on."
                        $row.ExitCode = 1
                        continue
                    }
                    if ($installed -and $installedVersion -ge $check.Version) {
                        Set-AlreadyInstalled -Row $row -Entry $installed
                        continue
                    }
                    if ($installed) {
                        if (-not $PSCmdlet.ShouldProcess("$($def.Name) $($installed.DisplayVersion)", 'Remove the older version')) {
                            Set-Declined -Row $row
                            continue
                        }
                        $removal = Remove-OlderKit -Entry $installed -Kit $kit -LogFile (Join-Path $runDir "$kit-remove.log")
                        if (-not $removal.Succeeded) {
                            $row.Result = $removal.Message
                            $row.ExitCode = $removal.ExitCode
                            continue
                        }
                    }
                    Write-Step "Installing $($def.Name) $($row.Version). The installer downloads more files. This can take several minutes..."
                    $code = Start-ProcessAndWait -FilePath $exe -Arguments $installerArgs -ReleaseAfterStart $lock
                    $outcome = ConvertFrom-BootstrapperExitCode -ExitCode $code
                }
                finally { $lock.Dispose() }
            }

            $row.ExitCode = $outcome.ExitCode
            $row.RebootRequired = $outcome.RebootRequired -or ($removal -and $removal.RebootRequired)
            $row.Succeeded = $outcome.Succeeded
            $row.Result = $outcome.Message
            if ($removal) {
                $row.Result = "Removed the older version $($installed.DisplayVersion). " + $row.Result
            }

            if ($outcome.Succeeded -and -not $outcome.AlreadyInstalled) {
                # Make sure the kit really is installed now.
                $after = Get-InstalledKit $kit
                if (-not $after -or (ConvertTo-Version $after.DisplayVersion) -lt (ConvertTo-Version $row.Version)) {
                    $row.Succeeded = $false
                    $row.ExitCode = 1
                    $row.Result = "The installer reported success, but $($def.Name) $($row.Version) is not installed in Windows."
                }
            }
        }
        catch {
            $row.Succeeded = $false
            $row.ExitCode = 1
            $row.Result = "Error: $($_.Exception.Message)"
        }
        if (-not $row.Succeeded -and $row.ExitCode -ne 1602 -and (Test-Path -LiteralPath $logFile)) {
            $row.Result += " Log: $logFile"
        }
    }

    # --- Report ----------------------------------------------------------------------------------
    Write-Host ''
    $results | Format-Table -AutoSize -Property Kit, Version, Result | Out-String -Width 4096 | Write-Host

    if (-not $WhatIfPreference) {
        $adkNow = Get-InstalledKit ADK
        $peNow = Get-InstalledKit WinPE
        if ($adkNow -and $peNow -and (ConvertTo-Version $adkNow.DisplayVersion) -ne (ConvertTo-Version $peNow.DisplayVersion)) {
            Write-Warning "The WinPE add-on ($($peNow.DisplayVersion)) does not match the ADK ($($adkNow.DisplayVersion)). They must have the same version."
        }
    }

    $failed = @($results | Where-Object { -not $_.Succeeded })
    $allOk = $failed.Count -eq 0
    $failureCode = if ($allOk) { 0 } else { $failed[0].ExitCode }
    $needReboot = @($results | Where-Object { $_.RebootRequired }).Count -gt 0
    if (-not $allOk -and $needReboot) {
        Write-Warning 'A part that did install needs a restart. Restart Windows before you use the ADK.'
    }

    $plan = Resolve-RebootPlan -Succeeded $allOk -RebootRequired $needReboot -SuppressReboot:$SuppressReboot -ForceReboot:$ForceReboot -FailureExitCode $failureCode

    switch ($plan.Action) {
        'Reboot' {
            $why = if ($needReboot) { 'The Windows ADK install needs a restart.' } else { 'A restart was asked for with -ForceReboot.' }
            if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Restart Windows in $RebootDelaySeconds seconds ($why)")) {
                # /f closes open programs. (shutdown.exe adds it by itself for any delay above 0.)
                & "$env:SystemRoot\System32\shutdown.exe" /r /f /t $RebootDelaySeconds /d p:4:2 /c "$why Windows restarts in $RebootDelaySeconds seconds."
                $shutdownCode = $LASTEXITCODE
                if ($shutdownCode -eq 1190) {
                    Write-Warning 'A shutdown or restart was already scheduled by something else. It was left as it is.'
                }
                elseif ($shutdownCode -ne 0) {
                    Exit-Script "Could not schedule the restart (shutdown.exe exit code $shutdownCode). Restart Windows yourself." 3010
                }
                else {
                    Write-Step "$why Windows restarts in $RebootDelaySeconds seconds. To cancel, run: shutdown /a"
                }
            }
            elseif ($WhatIfPreference -or -not $needReboot) {
                exit 0
            }
            else {
                Write-Warning 'A restart is needed to finish the install. You said No to the restart. Restart Windows soon.'
                exit 3010
            }
        }
        'Suppressed' {
            Write-Warning 'A restart is needed to finish the install. -SuppressReboot is set, so Windows does not restart now. Restart Windows soon.'
        }
        default {
            if ($WhatIfPreference) { Write-Step 'What if: nothing was changed.' }
            elseif ($allOk) { Write-Step 'Done. No restart needed.' }
            else { Write-Host "[ADK] FAILED: $($failed[0].Kit): $($failed[0].Result)" -ForegroundColor Red }
        }
    }
    exit $plan.ExitCode
}
catch {
    Write-Host "[ADK] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Verbose ($_ | Out-String)
    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize -Property Kit, Version, Result | Out-String -Width 4096 | Write-Host
        if (@($results | Where-Object { $_.RebootRequired }).Count -gt 0) {
            Write-Warning 'A part that did install needs a restart. Restart Windows before you use the ADK.'
        }
    }
    exit 1
}

