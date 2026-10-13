# Install-WindowsADK

A PowerShell script that downloads and installs the **Windows Assessment and Deployment Kit (ADK)**. It can also install the **Windows PE add-on**. It runs silently, so you can use it by hand or from Intune or Configuration Manager.

- **Default mode:** the script downloads the official installer from Microsoft, checks its digital signature, and installs it.
- **winget mode** (`-UseWinget`): the script installs the ADK with winget. **It does not work today (October 2026).** See [winget mode](#winget-mode).
- **Restarts:** the Microsoft installer never restarts Windows. The script restarts Windows after 60 seconds, but only if the install needs it. Add `-SuppressReboot` to never restart. Add `-ForceReboot` to always restart.

## Why this script exists

This script was made in response to [Veeam KB4885](https://www.veeam.com/kb4885): *Windows 11 24H2/25H2 | Server 2025 - Recovery Media Restore Fails with: The Local Security Authority cannot be contacted*.

- **The problem:** Veeam Agent for Microsoft Windows builds its Recovery Media (ISO or USB) from the Windows Recovery Environment (WinRE). After Microsoft's June 2026 security update, restores from that media fail with "The Local Security Authority cannot be contacted."
- **Microsoft's fix:** the September 8, 2026 security updates (KB5124008 for Windows 11 24H2/25H2, KB5122871 for Windows Server 2025). Install the update, then create the Recovery Media again.
- **Veeam's workaround:** build the Recovery Media with the Windows ADK and its matching Windows PE add-on instead of WinRE. This script installs both.

To use the workaround:

1. Install the ADK and the WinPE add-on with this script (see the [Quick start](#quick-start)). Use `-IncludeWinPE`.
2. Tell Veeam Agent to build the Recovery Media with the ADK. This command is from KB4885:

   ```powershell
   New-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam Endpoint Backup" -Name "ForceUseAdkForRecoveryMedia" -PropertyType DWORD -Value 1 -Force
   ```

3. Create the Veeam Recovery Media again. Media made before the change stays affected.

Always check [KB4885](https://www.veeam.com/kb4885) for Veeam's latest steps.

## Quick start

Open PowerShell **as Administrator**. Then run these steps in the same window.

**1. Turn on TLS 1.2 (for this window only).** Windows PowerShell 5.1 on some Windows versions still uses an old protocol that GitHub refuses. Without this line, the download can fail with `The underlying connection was closed: An unexpected error occurred on a send.`

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
```

**2. Download the script.** This saves it in your TEMP folder. You can use another folder, for example `C:\Temp\Install-WindowsADK.ps1`. Then use the same path in the next steps.

```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/acgdickie/Install-WindowsADK/main/Install-WindowsADK.ps1' -OutFile "$env:TEMP\Install-WindowsADK.ps1" -UseBasicParsing
```

This gets the newest version. To get a fixed release instead, use the link from the [Releases](https://github.com/acgdickie/Install-WindowsADK/releases) page, for example `https://github.com/acgdickie/Install-WindowsADK/releases/download/v1.0/Install-WindowsADK.ps1`.

**3. Dry run (changes nothing).** `-WhatIf` shows what the script would do, then stops. It downloads nothing, installs nothing and never restarts. So it cannot tell if the installed ADK is already up to date.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-WindowsADK.ps1" -IncludeWinPE -WhatIf
```

You should see lines that start with `What if:`, then `What if: nothing was changed.`

**4. Install, and never restart.** This installs the current ADK and the matching WinPE add-on. `-SuppressReboot` makes sure Windows does not restart, even if the install needs it.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-WindowsADK.ps1" -IncludeWinPE -SuppressReboot
```

The installers download about 2.5 GB. The script shows no progress while they work. This can take 5 to 15 minutes. Do not stop it.

**5. Check the result.**

```powershell
$LASTEXITCODE
```

| Result | Meaning |
|---|---|
| `0` | Done. No restart is needed. |
| `3010` | Done. Restart Windows when it suits you. |
| Any other number | It failed. The message on screen says why and where the log is. See [Troubleshooting](#troubleshooting). |

Notes:

- If you do not need the WinPE add-on, leave out `-IncludeWinPE`.
- `-ExecutionPolicy Bypass` lets the script run even when PowerShell blocks scripts. It applies to this one run only.
- If you leave out `-SuppressReboot`, Windows restarts after 60 seconds when the install needs a restart. Open programs close, and unsaved work is lost. To cancel the countdown, run `shutdown /a`.
- If you already have the script in a folder, you can also run it from there: `.\Install-WindowsADK.ps1 -IncludeWinPE -SuppressReboot`

## Requirements

- 64-bit Windows 10, Windows 11, Windows Server 2022 or Windows Server 2025. (Tested on Windows 11 23H2. The script does not check the Windows version.)
- Administrator rights. `-WhatIf` also needs them.
- Windows PowerShell 5.1 or PowerShell 7.
- Internet access. The installers download about 2.5 GB while they run.
- About 6 GB of free disk space. About 2.5 GB of it is always on drive C: (the installer's package cache), also when you use `-InstallPath`.
- For `-UseWinget` only: winget ("App Installer" from the Microsoft Store).

## What it installs

In October 2026, the default mode installs ADK **10.1.26100.9457** from these Microsoft links:

- ADK: `https://go.microsoft.com/fwlink/?linkid=2289980`
- WinPE add-on: `https://go.microsoft.com/fwlink/?linkid=2289981`

Microsoft can change the file behind these links, so the version can change. A new ADK release can also get new links. Then use `-AdkUrl` and `-WinPEUrl`. The script reads the version from the downloaded file and shows it.

If you leave out `-Features`, the installer installs its own default features:

| Feature ID | Tool | Default |
|---|---|---|
| `OptionId.DeploymentTools` | Deployment Tools (DISM, Oscdimg, Windows System Image Manager). The WinPE add-on needs it. | Yes |
| `OptionId.UserStateMigrationTool` | User State Migration Tool (USMT) | Yes |
| `OptionId.ImagingAndConfigurationDesigner` | Imaging and Configuration Designer (ICD) | Yes |
| `OptionId.ICDConfigurationDesigner` | Configuration Designer | Yes |
| `OptionId.WindowsPerformanceToolkit` | Windows Performance Toolkit | Yes |
| `OptionId.UEVTools` | UE-V Template Generator | Yes |
| `OptionId.AppmanSequencer` | App-V Sequencer | Yes |
| `OptionId.AppmanAutoSequencer` | App-V Auto Sequencer | Yes |
| `OptionId.SupplyChainTrustTools` | Supply Chain Trust Tools | Yes |
| `OptionId.ApplicationCompatibilityToolkit` | Application Compatibility Tools | No |
| `OptionId.VolumeActivationManagementTool` | Volume Activation Management Tool (VAMT) | No |
| `OptionId.WindowsAssessmentToolkit` | Windows Assessment Toolkit | No |
| `OptionId.MediaeXperienceAnalyzer` | Media eXperience Analyzer | No |

Configuration Manager needs `OptionId.DeploymentTools` and `OptionId.UserStateMigrationTool`. A wrong feature ID makes the installer stop with code 1001.

## Options

| Option | What it does |
|---|---|
| *(none)* | Normal Microsoft download and install. |
| `-IncludeWinPE` | Also install the Windows PE add-on. You need it to make WinPE boot media. |
| `-Features <list>` | ADK features to install, for example `OptionId.DeploymentTools,OptionId.UserStateMigrationTool`. Separate them with commas. To separate them with spaces, put the whole list in quotes. Use `+` for all features. See [What it installs](#what-it-installs). |
| `-InstallPath <folder>` | Install folder for the ADK and the WinPE add-on. Use a full path, for example `D:\Windows Kits\10`. Default: `C:\Program Files (x86)\Windows Kits\10` |
| `-SuppressReboot` | Never restart Windows, even when the install needs it. |
| `-ForceReboot` | Restart Windows after a successful install, even when the install does not need it. |
| `-RebootDelaySeconds <0-600>` | Seconds to wait before a restart. Default: 60. |
| `-AdkUrl <https link>` | Another download link for `adksetup.exe`, for example to keep one fixed ADK version. With `-IncludeWinPE`, also set `-WinPEUrl` to the add-on of the same version. The installer still downloads its files from Microsoft. |
| `-WinPEUrl <https link>` | Another download link for `adkwinpesetup.exe`. |
| `-UseWinget` | Install with winget. Does not work today. See [winget mode](#winget-mode). |
| `-WingetVersion <version>` | With `-UseWinget`: the exact package version. Read [winget mode](#winget-mode) first. |
| `-WhatIf` | Show what the script would do. Change nothing. |
| `-Confirm` | Ask before each install, each removal and each restart. |

Rules:

- You cannot use `-SuppressReboot` and `-ForceReboot` together.
- You cannot use `-RebootDelaySeconds` with `-SuppressReboot`.
- You can use `-WingetVersion` only with `-UseWinget`.
- You cannot use `-AdkUrl` or `-WinPEUrl` with `-UseWinget`.
- With `-IncludeWinPE`, the script adds `OptionId.DeploymentTools` to `-Features` if it is missing.

If you break a rule, the script stops with exit code 1 and changes nothing.

Full help is in the script:

```powershell
Get-Help .\Install-WindowsADK.ps1 -Full
```

## Restarts

The script always tells the Microsoft installer not to restart (`/norestart`). Then the script decides:

| Situation | Default | With `-SuppressReboot` | With `-ForceReboot` |
|---|---|---|---|
| The install needs a restart | Restarts Windows | No restart. Exit code 3010. | Restarts Windows |
| The install does not need a restart | No restart | No restart | Restarts Windows |
| The install failed | No restart | No restart | No restart |

- A restart comes after a countdown (`-RebootDelaySeconds`, default 60 seconds). When the time is up, open programs close, and unsaved work is lost.
- To cancel a countdown, run `shutdown /a`.
- An earlier ADK or WinPE install that still needs a restart counts as "the install needs a restart". The script restarts Windows for it.
- A restart that Windows needs for another reason (for example Windows Update) does not count. The script shows a warning only.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. No restart is needed. |
| 3010 | Success. A restart is needed, but it did not happen (`-SuppressReboot`, you said No at the restart question, or the script could not schedule the restart). |
| 1641 | Success. A restart was started (by this script, or one was already scheduled). |
| 1602 | You said No to a question (`-Confirm`). |
| 1618 | Another ADK or WinPE setup is already running. |
| 1 | A rule was broken, a check failed (for example a bad download or an ADK and WinPE version mismatch), or the script had an error. |
| Other | The error code of the Microsoft installer or of winget. The script shows what it means and where the log is. |

## Examples

Install the ADK only. Restart only if needed:

```powershell
.\Install-WindowsADK.ps1
```

Install the ADK and the WinPE add-on. Never restart:

```powershell
.\Install-WindowsADK.ps1 -IncludeWinPE -SuppressReboot
```

Install the ADK. Then restart Windows after 5 minutes, also when no restart is needed. (If the install fails, Windows does not restart.)

```powershell
.\Install-WindowsADK.ps1 -ForceReboot -RebootDelaySeconds 300
```

Install only the Deployment Tools and the User State Migration Tool:

```powershell
.\Install-WindowsADK.ps1 -Features OptionId.DeploymentTools,OptionId.UserStateMigrationTool
```

## Use with Intune or Configuration Manager

- **Always add `-SuppressReboot`.** Without it, the script restarts the device itself after 60 seconds. The user gets no restart notice from Intune or Configuration Manager and loses unsaved work. With it, the script exits with 3010, and Intune or Configuration Manager handles the restart.
- Start the script with `-File`. This keeps the exit code. (With `-Command`, PowerShell changes every exit code except 0 to 1.)
- Do not use `-UseWinget`. Microsoft does not support winget when it runs as SYSTEM.

**Intune** install command. Intune starts commands as 32-bit programs. `Sysnative` gives 64-bit PowerShell:

```text
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WindowsADK.ps1 -IncludeWinPE -SuppressReboot
```

**Configuration Manager** install command. Configuration Manager starts commands as 64-bit programs, and 64-bit programs cannot see `Sysnative`:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WindowsADK.ps1 -IncludeWinPE -SuppressReboot
```

Intune treats 3010 as a "soft reboot" and 1641 as a "hard reboot".

**Detection rule** (Intune rule type: Registry) for ADK 10.1.26100.9457:

- Key path: `HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{4f4f4626-ccb4-41ba-9c62-7ec9b0e113f3}`
- Value name: `Installed`
- Detection method: Integer comparison. Operator: Equals. Value: `1`
- Associated with a 32-bit app on 64-bit clients: No

With `-IncludeWinPE`, add a second rule with the same settings for the WinPE add-on 10.1.26100.9457:
`HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{f567a246-97ac-4217-a1ba-020ced2a8187}`

Notes:

- Use the `Installed` value. The installer writes the key when an install starts, but it sets `Installed` to 1 only when the install finishes.
- These key names are for version 10.1.26100.9457 only. Each ADK version has a different key. When Microsoft releases a new ADK, update the key names. Or keep one version: set `-AdkUrl` and `-WinPEUrl` to fixed download links.
- Do not use only the file `dism.exe` as the rule. An older ADK also has it, and it does not show the WinPE add-on.

## winget mode

> **Do not use `-UseWinget` today. Use the default mode.**

The problem (October 2026): winget's ADK packages are older than Microsoft's download page.

- winget's only 10.1.26100 ADK, version 10.1.26100.2454, cannot install any more. Microsoft replaced its download files, so its installer fails with error `0x80091007`.
- winget's newest ADK, 10.1.28000.1, installs. But Microsoft made it only for Windows 11, version 26H1, on Arm64 PCs. Configuration Manager does not support it, and winget has no WinPE add-on for it.

What the script does about this:

- `-UseWinget` with no `-WingetVersion` looks for the newest 10.1.26100 version that can still install. Today there is none, so the script stops at once, explains why, and changes nothing.
- When winget gets a newer 10.1.26100 version, the script picks it automatically. With `-IncludeWinPE`, winget must also have the WinPE add-on of the same version. No change to the script is needed.
- `-WingetVersion` lets you choose a version yourself. With `-IncludeWinPE`, winget must have a WinPE add-on of the same version, or the script stops before it installs anything.

If you really need the Arm64 kit:

```powershell
.\Install-WindowsADK.ps1 -UseWinget -WingetVersion 10.1.28000.1 -SuppressReboot
```

> **Warning:** The script sees 10.1.28000.1 as newer than 10.1.26100.9457. If 10.1.26100.9457 is installed, this command removes it and installs 10.1.28000.1. Do not use it on normal x64 PCs.

In winget mode, the script also:

- passes its own installer switches with `--override`, so `/norestart` is always used.
- passes `--force`, so winget runs the installer directly. Without it, winget can first run the old version's uninstaller, which can restart Windows by itself.
- passes `--skip-dependencies` for the WinPE add-on, so winget does not pull in the Arm64 ADK.

## Already installed

- If the same or a newer version is installed, the script skips it.
- If an older version is installed, the script removes it first, then installs the new version. (The Microsoft installer cannot install over an older version. It stops with code 2008.) The removal does not restart Windows. In default mode, the script removes the old version only after it has downloaded and checked the new installer.
- The script never downgrades. To install an older version, remove the newer one first.
- `-Features` has no effect on an ADK that is already installed. To add features, use Settings > Apps > Windows Assessment and Deployment Kit > Modify.
- An install that stopped halfway does not count as installed. The script installs it again.

## Safety checks

In all modes, before it installs anything, the script:

- stops if another ADK or WinPE setup is already running.
- checks that the WinPE add-on version is the same as the installed ADK version.

In default mode, the script also:

- downloads into a new folder that only SYSTEM and Administrators can change.
- checks that the downloaded installer has a valid digital signature from **Microsoft Corporation** and is the expected kit.
- keeps the installer file locked from the signature check until it starts, so nobody can swap it.

Before it removes an older version, the script checks the old uninstaller's signature the same way.

In winget mode, winget downloads the installer and checks its hash.

## Logs

Each run makes a new folder in the TEMP folder of the account that runs the script. When the script runs as SYSTEM (Intune, Configuration Manager), look in `C:\Windows\Temp` or `C:\Windows\SystemTemp`. With `-WhatIf`, the script makes no folder.

```text
%TEMP%\WindowsADK_<date-time>_<random>\
    adksetup.exe                        Downloaded ADK installer (default mode)
    adkwinpesetup.exe                   Downloaded WinPE add-on installer (default mode)
    ADK-install.log                     Log of the ADK installer
    ADK-install_<nnn>_<package>.log     Log of each ADK package
    ADK-remove.log                      Log of the removal of an older ADK (only when there was one)
    WinPE-install.log                   Log of the WinPE add-on installer
    WinPE-install_<nnn>_<package>.log   Log of each WinPE package
    WinPE-remove.log                    Log of the removal of an older WinPE add-on (only when there was one)
```

- The script prints the folder path when it starts. On a failure, it also prints the log path.
- If a package fails, find the error in the log of that package.
- The script does not delete this folder.
- The script does not save its own messages. If it fails with code 1 before an installer starts, there is no log. Then run the same command by hand in an Administrator PowerShell window and read the messages. For more detail, add `-Verbose`.

## Troubleshooting

| Message or code | What to do |
|---|---|
| `The underlying connection was closed: An unexpected error occurred on a send.` (when you download the script) | Turn on TLS 1.2 first. See step 1 of the [Quick start](#quick-start). The script turns on TLS 1.2 by itself for its own downloads. |
| `running scripts is disabled on this system` or `is not digitally signed` | Start the script with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path to the script>`, as in the [Quick start](#quick-start). |
| `Run this script as Administrator.` | Open PowerShell with "Run as administrator". |
| 1618 | Another setup is running. Wait for it to finish, then try again. |
| 2007 | A restart from an earlier ADK install is still pending. Restart Windows, then try again. |
| 1001 | The installer did not accept the features or the install path. Check the feature IDs. If the ADK is already installed in another folder, leave out `-InstallPath`. |
| 2001 | A newer ADK is already installed. The installer cannot downgrade. |
| 2004 or 15605 | The installer could not download its files. Check the internet connection and the proxy. |
| `0x80091007` (-2146889721) | The installer's files failed their hash check. This happens with an old ADK version whose files Microsoft replaced. Run the script without `-UseWinget`, `-WingetVersion`, `-AdkUrl` and `-WinPEUrl`. |
| `Could not remove the older ...` | The old version could not be removed. Remove it in Settings > Apps, then run the script again. |
| `winget has no ADK 10.1.26100.x that can still install` | See [winget mode](#winget-mode). Use the default mode. |
| `The add-on download is ..., but the installed ADK is ...` | The WinPE link gives another version than the installed ADK. Use `-WinPEUrl` with the add-on link for your ADK version, or install the current ADK first. |
| `winget has no WinPE add-on ... to match the installed ADK` | Run the script without `-UseWinget`. |
| `The WinPE add-on ... does not match the ADK` | The ADK and the WinPE add-on must have the same version. Run the script with `-IncludeWinPE` to fix it. |
| `The installed ADK has no Deployment Tools` | Add the Deployment Tools (Settings > Apps > Windows Assessment and Deployment Kit > Modify), then run the script again. |

## Tests

`Install-WindowsADK.Tests.ps1` holds 82 Pester tests for the decision logic: restarts, exit codes, installer arguments, version choice and detection. The tests do not install anything.

Run them with Pester 5 or later:

```powershell
Invoke-Pester -Path .\Install-WindowsADK.Tests.ps1 -Output Detailed
```

The tests load the script's functions with `$env:INSTALL_WINDOWSADK_FUNCTIONS_ONLY = '1'`. Without that variable, the script installs as usual, also when it is dot-sourced.

## Files

| File | Purpose |
|---|---|
| `Install-WindowsADK.ps1` | The install script. |
| `Install-WindowsADK.Tests.ps1` | Unit tests (Pester). |
| `README.md` | This file. |
| `LICENSE` | MIT license. |

## License

MIT. You can use, change and share this script, also for work. See [LICENSE](LICENSE).

The Windows ADK itself is Microsoft software. Its own Microsoft license applies when you install it.
