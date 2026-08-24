# Shared PowerShell profile for Windows PowerShell 5.1 and PowerShell 7.

$localBin = Join-Path $HOME ".local\bin"
$pathEntries = @($env:PATH -split [System.IO.Path]::PathSeparator)
if ($pathEntries -notcontains $localBin) {
  $env:PATH = "$localBin$([System.IO.Path]::PathSeparator)$env:PATH"
}

function l {
  Get-ChildItem @args
}

function la {
  Get-ChildItem -Force @args
}

function ll {
  Get-ChildItem -Force @args
}

function .. {
  Set-Location ..
}

function ... {
  Set-Location ..\..
}

function Compress-Zip {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$DestinationPath
  )

  Compress-Archive -Path $Path -DestinationPath $DestinationPath -Force
}

function Expand-Zip {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$DestinationPath = (Get-Location).Path
  )

  Expand-Archive -Path $Path -DestinationPath $DestinationPath -Force
}

if (-not $env:EDITOR) {
  if (Get-Command vim.exe -ErrorAction SilentlyContinue) {
    $env:EDITOR = "vim"
  } elseif (Get-Command code.cmd -ErrorAction SilentlyContinue) {
    $env:EDITOR = "code --wait"
  }
}

if (Get-Module -ListAvailable -Name PSReadLine) {
  Import-Module PSReadLine -ErrorAction SilentlyContinue

  $setOption = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
  if ($setOption) {
    $optionParameters = @{}
    if ($setOption.Parameters.ContainsKey("HistoryNoDuplicates")) {
      $optionParameters.HistoryNoDuplicates = $true
    }
    if ($setOption.Parameters.ContainsKey("MaximumHistoryCount")) {
      $optionParameters.MaximumHistoryCount = 50000
    }
    if ($optionParameters.Count -gt 0) {
      Set-PSReadLineOption @optionParameters
    }
  }

  if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
  }
}
