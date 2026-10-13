#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the decision logic in Install-WindowsADK.ps1.
# Run: Invoke-Pester -Path .\Install-WindowsADK.Tests.ps1 -Output Detailed

BeforeAll {
    # With this variable set, dot-sourcing loads the functions only and skips the install.
    $env:INSTALL_WINDOWSADK_FUNCTIONS_ONLY = '1'
    . (Join-Path $PSScriptRoot 'Install-WindowsADK.ps1')
    # The script runs its main body in strict mode, so the functions are tested that way too.
    Set-StrictMode -Version Latest
}

AfterAll {
    Remove-Item Env:\INSTALL_WINDOWSADK_FUNCTIONS_ONLY -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-FeatureList' {
    # 'powershell.exe -File' passes '-Features A,B' as ONE string, so lists must be split here.
    It 'splits <Text> into two features' -ForEach @(
        @{ Text = @('OptionId.DeploymentTools,OptionId.UserStateMigrationTool') }
        @{ Text = @('OptionId.DeploymentTools, OptionId.UserStateMigrationTool') }
        @{ Text = @('OptionId.DeploymentTools OptionId.UserStateMigrationTool') }
        @{ Text = @('OptionId.DeploymentTools', 'OptionId.UserStateMigrationTool') }
    ) {
        ConvertTo-FeatureList -Features $Text | Should -Be @('OptionId.DeploymentTools', 'OptionId.UserStateMigrationTool')
    }

    It 'keeps + (all features)' {
        ConvertTo-FeatureList -Features @('+') | Should -Be '+'
    }

    It 'returns nothing when no features are given' {
        ConvertTo-FeatureList -Features @() | Should -BeNullOrEmpty
    }

    It 'rejects <Text>' -ForEach @(
        @{ Text = 'OptionId.DeploymentTools;calc.exe' }
        @{ Text = 'Deployment Tools' }
        @{ Text = 'OptionId.DeploymentTools /installpath C:\Evil' }
    ) {
        { ConvertTo-FeatureList -Features @($Text) } | Should -Throw
    }
}

Describe 'Resolve-RebootPlan' {
    It 'returns <Action> / exit <ExitCode> when Succeeded=<Succeeded> RebootRequired=<RebootRequired> Suppress=<Suppress> Force=<Force>' -ForEach @(
        # Default behaviour: reboot only when the install needs it.
        @{ Succeeded = $true;  RebootRequired = $true;  Suppress = $false; Force = $false; Action = 'Reboot';     ExitCode = 1641 }
        @{ Succeeded = $true;  RebootRequired = $false; Suppress = $false; Force = $false; Action = 'None';       ExitCode = 0 }
        # -SuppressReboot: never reboot, tell the caller a reboot is still due.
        @{ Succeeded = $true;  RebootRequired = $true;  Suppress = $true;  Force = $false; Action = 'Suppressed'; ExitCode = 3010 }
        @{ Succeeded = $true;  RebootRequired = $false; Suppress = $true;  Force = $false; Action = 'None';       ExitCode = 0 }
        # -ForceReboot: reboot even when the install does not need it.
        @{ Succeeded = $true;  RebootRequired = $false; Suppress = $false; Force = $true;  Action = 'Reboot';     ExitCode = 1641 }
        @{ Succeeded = $true;  RebootRequired = $true;  Suppress = $false; Force = $true;  Action = 'Reboot';     ExitCode = 1641 }
    ) {
        $plan = Resolve-RebootPlan -Succeeded $Succeeded -RebootRequired $RebootRequired -SuppressReboot:$Suppress -ForceReboot:$Force
        $plan.Action   | Should -Be $Action
        $plan.ExitCode | Should -Be $ExitCode
    }

    It 'never reboots after a failed install, even with -ForceReboot, and returns the failure code <FailureExitCode>' -ForEach @(
        @{ RebootRequired = $false; Force = $true;  FailureExitCode = 1603 }
        @{ RebootRequired = $true;  Force = $false; FailureExitCode = -1978335226 }
    ) {
        $plan = Resolve-RebootPlan -Succeeded $false -RebootRequired $RebootRequired -ForceReboot:$Force -FailureExitCode $FailureExitCode
        $plan.Action   | Should -Be 'None'
        $plan.ExitCode | Should -Be $FailureExitCode
    }

    It 'returns exit code 1 for a failure that has no usable code' {
        (Resolve-RebootPlan -Succeeded $false -RebootRequired $false -FailureExitCode 0).ExitCode | Should -Be 1
    }
}

Describe 'ConvertTo-QuotedArgument' {
    # winget gets the whole installer command line as ONE argument. Bad escaping splits it apart.
    It 'quotes <Value> as <Expected>' -ForEach @(
        @{ Value = 'C:\Logs\adk.log';                 Expected = '"C:\Logs\adk.log"' }
        @{ Value = '';                                Expected = '""' }
        @{ Value = 'D:\';                             Expected = '"D:\\"' }
        @{ Value = '/quiet /log "C:\a b\x.log"';      Expected = '"/quiet /log \"C:\a b\x.log\""' }
        @{ Value = 'a\"b';                            Expected = '"a\\\"b"' }
    ) {
        ConvertTo-QuotedArgument $Value | Should -BeExactly $Expected
    }

    It 'survives a real round trip through the Windows command-line parser' {
        # A child process prints the first argument it received. It must equal the original value.
        $value = '/quiet /norestart /log "C:\My Logs\adk.log" /installpath "D:\"'
        $echo = Join-Path $TestDrive 'echo.ps1'
        Set-Content -LiteralPath $echo -Value '[Console]::Out.Write($args[0])'
        $out = Join-Path $TestDrive 'out.txt'
        $shell = (Get-Process -Id $PID).Path
        Start-Process -FilePath $shell -ArgumentList "-NoProfile -File `"$echo`" $(ConvertTo-QuotedArgument $value)" -RedirectStandardOutput $out -Wait -NoNewWindow
        Get-Content -LiteralPath $out -Raw | Should -BeExactly $value
    }
}

Describe 'Get-BootstrapperArguments' {
    # The installer must always get /norestart. Without it, Burn's /quiet mode restarts Windows by itself.
    It 'builds the minimum silent, no-restart command line' {
        Get-BootstrapperArguments -LogFile 'C:\Logs\adk.log' |
            Should -BeExactly '/quiet /norestart /ceip off /log "C:\Logs\adk.log"'
    }

    It 'adds the requested features, separated by spaces' {
        Get-BootstrapperArguments -LogFile 'C:\Logs\adk.log' -Features 'OptionId.DeploymentTools', 'OptionId.UserStateMigrationTool' |
            Should -BeExactly '/quiet /norestart /ceip off /features OptionId.DeploymentTools OptionId.UserStateMigrationTool /log "C:\Logs\adk.log"'
    }

    It 'quotes the install path and drops a trailing backslash (a \" would break the quoting)' {
        Get-BootstrapperArguments -LogFile 'C:\My Logs\adk.log' -InstallPath 'D:\Windows Kits\' |
            Should -BeExactly '/quiet /norestart /ceip off /installpath "D:\Windows Kits" /log "C:\My Logs\adk.log"'
    }
}

Describe 'Get-KitUninstallCommand' {
    # The ADK installer refuses to install over an older ADK (exit 2008), so the old one is removed
    # first. Its own uninstall command has no /norestart, and without it Windows can restart at once.
    It 'adds /norestart and a log to the quiet uninstall command' {
        $cmd = Get-KitUninstallCommand -QuietUninstallString '"C:\ProgramData\Package Cache\{073af81c-64f5-43a2-9e4b-1d222c6b8434}\adksetup.exe" /uninstall /quiet' -LogFile 'C:\My Logs\u.log'
        $cmd.FilePath  | Should -BeExactly 'C:\ProgramData\Package Cache\{073af81c-64f5-43a2-9e4b-1d222c6b8434}\adksetup.exe'
        $cmd.Arguments | Should -BeExactly '/uninstall /quiet /norestart /log "C:\My Logs\u.log"'
    }

    It 'does not add /norestart twice' {
        (Get-KitUninstallCommand -QuietUninstallString '"C:\Cache\adksetup.exe" /uninstall /quiet /norestart' -LogFile 'C:\u.log').Arguments |
            Should -BeExactly '/uninstall /quiet /norestart /log "C:\u.log"'
    }

    It 'reads a program path without quotes' {
        (Get-KitUninstallCommand -QuietUninstallString 'C:\Cache\adksetup.exe /uninstall /quiet' -LogFile 'C:\u.log').FilePath |
            Should -BeExactly 'C:\Cache\adksetup.exe'
    }

    It 'returns $null when there is no uninstall command' {
        Get-KitUninstallCommand -QuietUninstallString $null -LogFile 'C:\u.log' | Should -BeNullOrEmpty
        Get-KitUninstallCommand -QuietUninstallString '' -LogFile 'C:\u.log' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-BootstrapperExitCode' {
    It 'exit <ExitCode> -> Succeeded=<Succeeded> RebootRequired=<RebootRequired>' -ForEach @(
        @{ ExitCode = 0;           Succeeded = $true;  RebootRequired = $false }
        @{ ExitCode = 3010;        Succeeded = $true;  RebootRequired = $true }   # ERROR_SUCCESS_REBOOT_REQUIRED
        @{ ExitCode = 1641;        Succeeded = $true;  RebootRequired = $true }   # ERROR_SUCCESS_REBOOT_INITIATED
        @{ ExitCode = 1618;        Succeeded = $false; RebootRequired = $false }  # another install is running
        @{ ExitCode = 2007;        Succeeded = $false; RebootRequired = $false }  # ADK: earlier restart still pending
        @{ ExitCode = 1603;        Succeeded = $false; RebootRequired = $false }
        @{ ExitCode = -2147023293; Succeeded = $false; RebootRequired = $false }  # 0x80070643 fatal error
    ) {
        $r = ConvertFrom-BootstrapperExitCode -ExitCode $ExitCode
        $r.Succeeded      | Should -Be $Succeeded
        $r.RebootRequired | Should -Be $RebootRequired
        $r.ExitCode       | Should -Be $ExitCode
    }

    It 'points to the newest version when the installer files were replaced (0x80091007 hash mismatch)' {
        # Seen 2026-10-12: winget's ADK 10.1.26100.2454 now downloads the 10.1.26100.9457 files and fails.
        $r = ConvertFrom-BootstrapperExitCode -ExitCode -2146889721
        $r.Succeeded | Should -BeFalse
        $r.Message   | Should -Match 'newest version'
    }

    It 'explains every failure code in its message' -ForEach @(
        @{ ExitCode = 1618 }, @{ ExitCode = 2007 }, @{ ExitCode = 1603 }, @{ ExitCode = -2147023293 }
    ) {
        (ConvertFrom-BootstrapperExitCode -ExitCode $ExitCode).Message | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-BurnLogExitCode' {
    BeforeAll {
        $prefix = '[14B8:3A34][2026-10-12T10:29:12]'
        function New-Log([string[]]$Lines) {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.log')
            Set-Content -LiteralPath $path -Value $Lines
            $path
        }
    }

    It 'reads <Hex> as <Expected>' -ForEach @(
        @{ Hex = '0x0';        Expected = 0 }
        @{ Hex = '0xbc2';      Expected = 3010 }
        @{ Hex = '0x80070643'; Expected = -2147023293 }
    ) {
        $log = New-Log @("${prefix}i000: Apply complete, result: 0x0, restart: None", "${prefix}i007: Exit code: $Hex, restarting: No")
        Get-BurnLogExitCode -Path $log | Should -Be $Expected
    }

    It 'uses the last exit line when the log holds more than one run' {
        $log = New-Log @("${prefix}i007: Exit code: 0x0, restarting: No", "${prefix}i007: Exit code: 0xbc2, restarting: No")
        Get-BurnLogExitCode -Path $log | Should -Be 3010
    }

    It 'returns $null when the log has no exit line' {
        $log = New-Log @("${prefix}i000: Restart action is Prompt")
        Get-BurnLogExitCode -Path $log | Should -BeNullOrEmpty
    }

    It 'returns $null when the log file does not exist' {
        Get-BurnLogExitCode -Path (Join-Path $TestDrive 'missing.log') | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-WingetResult' {
    # winget runs the ADK as a plain 'exe' installer. It knows no reboot codes for it, so an
    # installer 3010 arrives as SHELLEXEC_INSTALL_FAILED (0x8A150006). The Burn log tells the truth.
    It 'winget <Winget> + installer <Installer> -> Succeeded=<Succeeded> Reboot=<Reboot> AlreadyInstalled=<Already> ExitCode=<ExitCode>' -ForEach @(
        @{ Winget = 0;           Installer = $null; Succeeded = $true;  Reboot = $false; Already = $false; ExitCode = 0 }
        @{ Winget = 0;           Installer = 0;     Succeeded = $true;  Reboot = $false; Already = $false; ExitCode = 0 }
        @{ Winget = 0;           Installer = 3010;  Succeeded = $true;  Reboot = $true;  Already = $false; ExitCode = 3010 }
        @{ Winget = -1978335226; Installer = 3010;  Succeeded = $true;  Reboot = $true;  Already = $false; ExitCode = 3010 }
        @{ Winget = -1978335226; Installer = 1641;  Succeeded = $true;  Reboot = $true;  Already = $false; ExitCode = 1641 }
        @{ Winget = -1978335226; Installer = 1603;  Succeeded = $false; Reboot = $false; Already = $false; ExitCode = 1603 }
        @{ Winget = -1978335226; Installer = $null; Succeeded = $false; Reboot = $false; Already = $false; ExitCode = -1978335226 }
        @{ Winget = -1978334967; Installer = $null; Succeeded = $true;  Reboot = $true;  Already = $false; ExitCode = -1978334967 } # REBOOT_REQUIRED_TO_FINISH
        @{ Winget = -1978334965; Installer = $null; Succeeded = $true;  Reboot = $true;  Already = $false; ExitCode = -1978334965 } # REBOOT_INITIATED
        @{ Winget = -1978335189; Installer = $null; Succeeded = $true;  Reboot = $false; Already = $true;  ExitCode = -1978335189 } # UPDATE_NOT_APPLICABLE
        @{ Winget = -1978335135; Installer = $null; Succeeded = $true;  Reboot = $false; Already = $true;  ExitCode = -1978335135 } # PACKAGE_ALREADY_INSTALLED
        @{ Winget = -1978335212; Installer = $null; Succeeded = $false; Reboot = $false; Already = $false; ExitCode = -1978335212 } # NO_APPLICATIONS_FOUND
        @{ Winget = -1978334966; Installer = $null; Succeeded = $false; Reboot = $false; Already = $false; ExitCode = -1978334966 } # REBOOT_REQUIRED_FOR_INSTALL
    ) {
        $r = Resolve-WingetResult -WingetExitCode $Winget -InstallerExitCode $Installer
        $r.Succeeded        | Should -Be $Succeeded
        $r.RebootRequired   | Should -Be $Reboot
        $r.AlreadyInstalled | Should -Be $Already
        $r.ExitCode         | Should -Be $ExitCode
        $r.Message          | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-WingetVersionList' {
    It 'returns only the version lines of "winget show --versions"' {
        # Captured from winget v1.29.380 on 2026-10-12, including a progress-spinner line.
        $text = @(
            '   -   '
            'Found Windows Assessment and Deployment Kit [Microsoft.WindowsADK]'
            'Version'
            '---------------'
            '10.1.28000.1'
            '10.1.26100.2454'
            '10.1.25398.1'
            '10.1.14393.8069'
        )
        ConvertFrom-WingetVersionList -Text $text | Should -Be @('10.1.28000.1', '10.1.26100.2454', '10.1.25398.1', '10.1.14393.8069')
    }

    It 'returns nothing when winget found no package' {
        ConvertFrom-WingetVersionList -Text @('No package found matching input criteria.') | Should -BeNullOrEmpty
    }
}

Describe 'Select-WingetKitVersion' {
    It 'picks <Expected> from ADK <Adk> and WinPE <WinPE> (IncludeWinPE=<Include>)' -ForEach @(
        # winget today: newest ADK is the Arm64-only 28000 line, which must be skipped.
        @{ Adk = @('10.1.28000.1', '10.1.26100.2454', '10.1.25398.1'); WinPE = @('10.1.26100.2454'); Include = $true;  Expected = '10.1.26100.2454' }
        @{ Adk = @('10.1.28000.1', '10.1.26100.2454', '10.1.25398.1'); WinPE = @('10.1.26100.2454'); Include = $false; Expected = '10.1.26100.2454' }
        # A newer ADK without a matching WinPE add-on is only used when WinPE is not wanted.
        @{ Adk = @('10.1.26100.9457', '10.1.26100.2454'); WinPE = @('10.1.26100.2454'); Include = $true;  Expected = '10.1.26100.2454' }
        @{ Adk = @('10.1.26100.9457', '10.1.26100.2454'); WinPE = @('10.1.26100.2454'); Include = $false; Expected = '10.1.26100.9457' }
        # Compare as numbers, not text: 10001 > 9457.
        @{ Adk = @('10.1.26100.9457', '10.1.26100.10001'); WinPE = @(); Include = $false; Expected = '10.1.26100.10001' }
    ) {
        Select-WingetKitVersion -AdkVersions $Adk -WinPEVersions $WinPE -ReleaseLine '10.1.26100' -IncludeWinPE:$Include |
            Should -Be $Expected
    }

    It 'returns $null when no version is on the release line' {
        Select-WingetKitVersion -AdkVersions @('10.1.28000.1') -WinPEVersions @() -ReleaseLine '10.1.26100' |
            Should -BeNullOrEmpty
    }

    It 'returns $null when WinPE is wanted but no ADK version has a matching add-on' {
        Select-WingetKitVersion -AdkVersions @('10.1.26100.9457') -WinPEVersions @('10.1.26100.2454') -ReleaseLine '10.1.26100' -IncludeWinPE |
            Should -BeNullOrEmpty
    }

    It 'skips versions that are known not to install' {
        # winget on 2026-10-12: 10.1.26100.2454 is the only 26100 version, and it cannot install any more.
        Select-WingetKitVersion -AdkVersions @('10.1.28000.1', '10.1.26100.2454', '10.1.25398.1') -WinPEVersions @() -ReleaseLine '10.1.26100' -ExcludeVersion '10.1.26100.2454' |
            Should -BeNullOrEmpty
        Select-WingetKitVersion -AdkVersions @('10.1.26100.9457', '10.1.26100.2454') -WinPEVersions @('10.1.26100.9457', '10.1.26100.2454') -ReleaseLine '10.1.26100' -IncludeWinPE -ExcludeVersion '10.1.26100.2454' |
            Should -Be '10.1.26100.9457'
    }
}

Describe 'Select-KitEntry' {
    BeforeAll {
        $adkCode = '{80114C7E-A1FE-8C0E-E86C-38C5486AF51E}'
        $peCode  = '{C65E68FC-10D3-CB37-5B36-4880129E14E8}'
        # Same shape as Get-UninstallEntry output. Burn sets Installed=1 only when an install has finished.
        function New-Entry($Name, $Version, $Codes, $Key, $Installed = 1) {
            [pscustomobject]@{ PSChildName = $Key; DisplayName = $Name; DisplayVersion = $Version; BundleUpgradeCode = $Codes; Installed = $Installed }
        }
        $adkNew = New-Entry 'Windows Assessment and Deployment Kit' '10.1.26100.9457' @($adkCode) '{4f4f4626-ccb4-41ba-9c62-7ec9b0e113f3}'
        $adkOld = New-Entry 'Windows Assessment and Deployment Kit' '10.1.26100.2454' @($adkCode) '{11111111-1111-1111-1111-111111111111}'
        $pe     = New-Entry 'Windows Assessment and Deployment Kit Windows Preinstallation Environment Add-ons' '10.1.26100.9457' @($peCode) '{f567a246-97ac-4217-a1ba-020ced2a8187}'
        $sdk    = New-Entry 'Windows Software Development Kit - Windows 10.0.26100.1' '10.1.26100.1' $null '{22222222-2222-2222-2222-222222222222}'
        $noCode = New-Entry 'Windows Assessment and Deployment Kit' '10.1.25398.1' $null '{073af81c-64f5-43a2-9e4b-1d222c6b8434}'
        $reboot = New-Entry $null $null $null '{4f4f4626-ccb4-41ba-9c62-7ec9b0e113f3}.RebootRequired'
    }

    It 'finds the ADK but not the WinPE add-on, whose name starts the same way' {
        (Select-KitEntry -Entries @($pe, $adkNew, $sdk, $reboot) -Kit ADK).DisplayVersion | Should -Be '10.1.26100.9457'
        (Select-KitEntry -Entries @($pe, $sdk) -Kit ADK) | Should -BeNullOrEmpty
    }

    It 'finds the WinPE add-on but not the ADK' {
        (Select-KitEntry -Entries @($adkNew, $pe) -Kit WinPE).PSChildName | Should -Be '{f567a246-97ac-4217-a1ba-020ced2a8187}'
        (Select-KitEntry -Entries @($adkNew) -Kit WinPE) | Should -BeNullOrEmpty
    }

    It 'picks the newest version when more than one is registered' {
        (Select-KitEntry -Entries @($adkOld, $adkNew) -Kit ADK).DisplayVersion | Should -Be '10.1.26100.9457'
    }

    It 'finds the ADK by its upgrade code when the display name is different (for example translated)' {
        $renamed = New-Entry 'Windows-Bewertungs- und Bereitstellungskit' '10.1.26100.9457' @($adkCode) '{33333333-3333-3333-3333-333333333333}'
        (Select-KitEntry -Entries @($renamed, $pe) -Kit ADK).PSChildName | Should -Be '{33333333-3333-3333-3333-333333333333}'
    }

    It 'falls back to the display name when the entry has no upgrade code' {
        (Select-KitEntry -Entries @($noCode) -Kit ADK).DisplayVersion | Should -Be '10.1.25398.1'
    }

    It 'ignores an install that never finished (no Installed=1)' {
        $interrupted = New-Entry 'Windows Assessment and Deployment Kit' '10.1.26100.9457' @($adkCode) '{44444444-4444-4444-4444-444444444444}' $null
        Select-KitEntry -Entries @($interrupted) -Kit ADK | Should -BeNullOrEmpty
        (Select-KitEntry -Entries @($interrupted, $adkOld) -Kit ADK).DisplayVersion | Should -Be '10.1.26100.2454'
    }

    It 'reports a restart still pending from an earlier install (Burn ".RebootRequired" key)' {
        (Select-KitEntry -Entries @($adkNew, $reboot) -Kit ADK).RebootPending | Should -BeTrue
        (Select-KitEntry -Entries @($adkNew) -Kit ADK).RebootPending | Should -BeFalse
        (Select-KitEntry -Entries @($pe, $reboot) -Kit WinPE).RebootPending | Should -BeFalse
    }
}

Describe 'Test-KitInstaller' {
    It 'rejects a file without a valid signature' {
        $fake = Join-Path $TestDrive 'adksetup.exe'
        Set-Content -LiteralPath $fake -Value 'not a real installer'
        $r = Test-KitInstaller -Path $fake -Kit ADK
        $r.IsTrusted | Should -BeFalse
        $r.Reason    | Should -Not -BeNullOrEmpty
    }

    It 'rejects a file signed by a different Microsoft certificate (Microsoft Windows)' {
        $r = Test-KitInstaller -Path "$env:SystemRoot\System32\notepad.exe" -Kit ADK
        $r.IsTrusted | Should -BeFalse
    }

    It 'rejects a file signed by Microsoft Corporation that is a different product' {
        $other = @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $other) { Set-ItResult -Skipped -Because 'no Microsoft Corporation signed program was found'; return }
        (Get-AuthenticodeSignature -LiteralPath $other).SignerCertificate.Subject | Should -Match '^CN=Microsoft Corporation,'

        $r = Test-KitInstaller -Path $other -Kit ADK
        $r.IsTrusted | Should -BeFalse
    }
}
