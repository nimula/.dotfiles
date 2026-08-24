[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $HOME ".dotfiles"),
  [switch]$DryRun,
  [switch]$SkipPackageInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Invoke-Git {
  param([string[]]$ArgumentList)

  if ($DryRun) {
    Write-Host "+ git $($ArgumentList -join ' ')"
    return
  }

  Write-Verbose "+ git $($ArgumentList -join ' ')"
  & git.exe @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "git exited with code $LASTEXITCODE"
  }
}

if ($env:OS -ne "Windows_NT") {
  throw "install.ps1 only supports Windows. Use install.sh on Linux or macOS."
}

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
  throw "Git for Windows is required. Install it before running this script."
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if (Test-Path -LiteralPath $InstallDir) {
  if (-not (Test-Path -LiteralPath (Join-Path $InstallDir ".git"))) {
    throw "Install directory exists but is not a Git repository: $InstallDir"
  }

  Write-Info "Updating dotfiles in $InstallDir"
  Invoke-Git -ArgumentList @("-C", $InstallDir, "pull", "--rebase", "--autostash")
} else {
  Write-Info "Cloning dotfiles to $InstallDir"
  Invoke-Git -ArgumentList @(
    "clone",
    "https://github.com/nimula/.dotfiles.git",
    $InstallDir
  )

  if ($DryRun) {
    Write-Info "Dry run complete. Windows setup was not invoked because the repository does not exist yet."
    return
  }
}

$setupScript = Join-Path $InstallDir "scripts\setup-windows.ps1"
if (-not (Test-Path -LiteralPath $setupScript)) {
  throw "Windows setup script not found: $setupScript"
}

$setupParameters = @{
  InstallDir         = $InstallDir
  DryRun             = $DryRun.IsPresent
  SkipPackageInstall = $SkipPackageInstall.IsPresent
  Verbose            = ($VerbosePreference -eq "Continue")
}

& $setupScript @setupParameters
