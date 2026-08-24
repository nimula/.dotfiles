Set-StrictMode -Version 2.0

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
  param([string]$Message)
  Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarningMessage {
  param([string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Invoke-DotfilesCommand {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string[]]$ArgumentList = @(),

    [switch]$DryRun
  )

  if ($DryRun) {
    Write-Host "+ $FilePath $($ArgumentList -join ' ')"
    return
  }

  Write-Verbose "+ $FilePath $($ArgumentList -join ' ')"
  & $FilePath @ArgumentList
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath exited with code $LASTEXITCODE"
  }
}

function Set-ManagedBlock {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Content,

    [switch]$DryRun
  )

  $newline = [Environment]::NewLine
  $startMarker = "# >>> dotfiles:$Name >>>"
  $endMarker = "# <<< dotfiles:$Name <<<"
  $block = "$startMarker$newline$Content$newline$endMarker"

  $existing = ""
  if (Test-Path -LiteralPath $Path) {
    $existing = [System.IO.File]::ReadAllText($Path)
  }

  $pattern = "(?ms)^$([Regex]::Escape($startMarker))\r?\n.*?^$([Regex]::Escape($endMarker))(?:\r?\n)?"
  if ([Regex]::IsMatch($existing, $pattern)) {
    $updated = [Regex]::Replace(
      $existing,
      $pattern,
      [System.Text.RegularExpressions.MatchEvaluator]{ param($match) "$block$newline" }
    )
  } else {
    $separator = if ([string]::IsNullOrWhiteSpace($existing)) {
      ""
    } elseif ($existing.EndsWith("`n")) {
      $newline
    } else {
      "$newline$newline"
    }
    $updated = "$existing$separator$block$newline"
  }

  if ($updated -eq $existing) {
    Write-Info "Managed block '$Name' is already up to date in $Path"
    return
  }

  if ($DryRun) {
    Write-Host "+ update managed block '$Name' in $Path"
    return
  }

  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $updated, $utf8WithoutBom)
  Write-Success "Updated managed block '$Name' in $Path"
}
