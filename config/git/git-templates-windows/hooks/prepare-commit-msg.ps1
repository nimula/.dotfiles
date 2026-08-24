[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$CommitMessageFile,

  [Parameter(Position = 1)]
  [AllowEmptyString()]
  [string]$CommitSource = "",

  [Parameter(Position = 2)]
  [AllowEmptyString()]
  [string]$CommitObject = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ($CommitSource -eq "merge" -or $CommitSource -eq "message") {
  return
}

$diff = (& git.exe diff --cached | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read the staged Git diff."
}

if ([string]::IsNullOrWhiteSpace($diff)) {
  return
}

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY) -and (Test-Path -LiteralPath ".env")) {
  foreach ($line in Get-Content -LiteralPath ".env") {
    if ($line -match '^\s*OPENAI_API_KEY\s*=\s*(.*?)\s*$') {
      $apiKey = $Matches[1].Trim()
      if (
        $apiKey.Length -ge 2 -and
        (($apiKey.StartsWith('"') -and $apiKey.EndsWith('"')) -or
        ($apiKey.StartsWith("'") -and $apiKey.EndsWith("'")))
      ) {
        $apiKey = $apiKey.Substring(1, $apiKey.Length - 2)
      }
      $env:OPENAI_API_KEY = $apiKey
      break
    }
  }
}

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
  Write-Host "[INFO] OPENAI_API_KEY is not set. Skipping AI-generated commit message."
  return
}

$conventionalCommits = @'
# Conventional commits
#
# <type>[optional scope]: <description>
#
# [optional body]
#
# [optional footer(s)]
#
# Type must be one of: build, ci, docs, feat, fix, perf, refactor, style, test
'@

$normalPrompt = @'
You are a commit message generator. Analyze the staged diff and generate a commit message.

Rules:
- Use English.
- Use Conventional Commits with one of: build, ci, docs, feat, fix, perf, refactor, style, test.
- Keep the subject line under 80 characters.
- After a blank line, list key changes as concise bullet points.
- Do not use code fences or add explanations outside the commit message.
- Return the commit message only.
'@

$amendPrompt = @'
You are generating a commit message to supplement the previous commit. Analyze the staged diff and summarize the additional changes.

Rules:
- Use English.
- Use Conventional Commits with one of: build, ci, docs, feat, fix, perf, refactor, style, test.
- Keep the subject line under 80 characters.
- After a blank line, list changes introduced by the amendment as concise bullet points.
- Do not use code fences or add explanations outside the commit message.
- Return the commit message only.
'@

$prompt = if ($CommitSource -eq "commit" -and $CommitObject) {
  $amendPrompt
} else {
  $normalPrompt
}

$payload = @{
  model = "gpt-5.4-mini"
  messages = @(
    @{
      role = "system"
      content = $prompt
    },
    @{
      role = "user"
      content = $diff
    }
  )
  max_completion_tokens = 2048
} | ConvertTo-Json -Depth 6 -Compress

$headers = @{
  Authorization = "Bearer $env:OPENAI_API_KEY"
}

Write-Host "[INFO] Calling OpenAI API to generate commit message. Please wait..."

try {
  $response = Invoke-RestMethod `
    -Uri "https://api.openai.com/v1/chat/completions" `
    -Method Post `
    -Headers $headers `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($payload))
} catch {
  Write-Error "OpenAI API request failed: $($_.Exception.Message)"
  exit 1
}

$commitMessage = [string]$response.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($commitMessage)) {
  Write-Error "OpenAI API returned an empty commit message."
  exit 1
}

$existingMessage = [System.IO.File]::ReadAllText($CommitMessageFile)
$newline = [Environment]::NewLine
$updatedMessage = "$($commitMessage.Trim())$newline$newline$existingMessage$newline$newline$conventionalCommits$newline"
$utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($CommitMessageFile, $updatedMessage, $utf8WithoutBom)
