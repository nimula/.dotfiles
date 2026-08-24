[CmdletBinding()]
param(
  [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
  [switch]$DryRun,
  [switch]$SkipPackageInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "utils.ps1")

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-GitPath {
  param([string]$Path)
  return $Path.Replace("\", "/")
}

function Install-OpenSshClient {
  if ($SkipPackageInstall) {
    Write-Info "Skipping OpenSSH Client installation."
    return
  }

  $agentService = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
  if ($agentService) {
    Write-Info "ssh-agent is already installed (status: $($agentService.Status)). Its startup settings were not changed."
    return
  }

  Write-Info "Windows OpenSSH Client is required to install the ssh-agent service."

  if ($DryRun) {
    Write-Host "+ Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    Write-Info "The service would be installed but not enabled or started."
    return
  }

  $installScript = @'
$ErrorActionPreference = "Stop"
$capability = Get-WindowsCapability -Online |
  Where-Object { $_.Name -like "OpenSSH.Client*" } |
  Select-Object -First 1

if (-not $capability) {
  throw "Windows OpenSSH Client capability was not found."
}

if ($capability.State -ne "Installed") {
  Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
'@

  $encodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($installScript)
  )

  if (Test-IsAdministrator) {
    & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) {
      throw "Windows OpenSSH Client installation failed with code $LASTEXITCODE."
    }
  } else {
    Write-Info "Administrator approval is required to install Windows OpenSSH Client."
    $process = Start-Process `
      -FilePath "powershell.exe" `
      -Verb RunAs `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-EncodedCommand", $encodedCommand) `
      -Wait `
      -PassThru

    if ($process.ExitCode -ne 0) {
      throw "Windows OpenSSH Client installation failed with code $($process.ExitCode)."
    }
  }

  $agentService = Get-Service -Name "ssh-agent" -ErrorAction SilentlyContinue
  if (-not $agentService) {
    throw "OpenSSH Client installation completed, but the ssh-agent service was not found."
  }

  Write-Success "Installed ssh-agent. The service was not enabled or started."
}

function Set-PowerShellProfile {
  $profileSource = Join-Path $InstallDir "config\powershell\profile.ps1"
  if (-not (Test-Path -LiteralPath $profileSource)) {
    throw "PowerShell profile source not found: $profileSource"
  }

  $escapedSource = $profileSource.Replace("'", "''")
  Set-ManagedBlock `
    -Path $PROFILE.CurrentUserAllHosts `
    -Name "powershell-profile" `
    -Content ". '$escapedSource'" `
    -DryRun:$DryRun
}

function Add-GitInclude {
  param([string]$Path)

  $gitPath = ConvertTo-GitPath $Path
  $includes = @(& git.exe config --global --get-all include.path 2>$null)
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
    throw "Unable to read global Git include paths."
  }

  if ($includes -contains $gitPath) {
    Write-Info "Git include is already configured: $gitPath"
    return
  }

  Invoke-DotfilesCommand `
    -FilePath "git.exe" `
    -ArgumentList @("config", "--global", "--add", "include.path", $gitPath) `
    -DryRun:$DryRun
}

function Set-GitConfig {
  if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "Git for Windows is required to configure Git settings."
  }

  $commonConfig = Join-Path $InstallDir "config\git\.gitconfig.common"
  $globalIgnore = Join-Path $InstallDir "config\git\.gitignore.global"
  $templateDir = Join-Path $InstallDir "config\git\git-templates-windows"

  foreach ($requiredPath in @($commonConfig, $globalIgnore, $templateDir)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
      throw "Required Git configuration path not found: $requiredPath"
    }
  }

  Add-GitInclude -Path $commonConfig

  Invoke-DotfilesCommand `
    -FilePath "git.exe" `
    -ArgumentList @(
      "config",
      "--global",
      "core.excludesfile",
      (ConvertTo-GitPath $globalIgnore)
    ) `
    -DryRun:$DryRun

  Invoke-DotfilesCommand `
    -FilePath "git.exe" `
    -ArgumentList @(
      "config",
      "--global",
      "init.templatedir",
      (ConvertTo-GitPath $templateDir)
    ) `
    -DryRun:$DryRun
}

function Set-SshConfig {
  $sshCommon = Join-Path $InstallDir "config\ssh\_commons.windows.conf"
  if (-not (Test-Path -LiteralPath $sshCommon)) {
    throw "Windows SSH config not found: $sshCommon"
  }

  $sshDirectory = Join-Path $HOME ".ssh"
  $sshConfig = Join-Path $sshDirectory "config"
  $includePath = ConvertTo-GitPath $sshCommon
  $includeBlock = "Host *`n  Include `"$includePath`""

  Set-ManagedBlock `
    -Path $sshConfig `
    -Name "windows-ssh" `
    -Content $includeBlock `
    -DryRun:$DryRun

  $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
  if (-not $sshCommand) {
    Write-WarningMessage "ssh.exe is unavailable; SSH config validation was skipped."
    return
  }

  if ($DryRun) {
    Write-Host "+ ssh.exe -G github.com"
    return
  }

  $sshOutput = & ssh.exe -G github.com 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Windows OpenSSH rejected the generated config: $($sshOutput -join [Environment]::NewLine)"
  }

  Write-Success "Windows OpenSSH accepted the generated config."
}

function Main {
  if ($env:OS -ne "Windows_NT") {
    throw "setup-windows.ps1 only supports Windows."
  }

  $script:InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
  Write-Info "Installing Windows dotfiles from $script:InstallDir"

  Install-OpenSshClient
  Set-PowerShellProfile
  Set-GitConfig
  Set-SshConfig

  Write-Success "Windows dotfiles setup complete. Open a new PowerShell session to load the profile."
}

Main
