<#
.SYNOPSIS
    Point ask at a model that supports tool calls.

.DESCRIPTION
    Checks that Ollama is up, pulls the model if it isn't installed, confirms
    Ollama reports the "tools" capability for it, and saves it as
    "tools_model" in ~/.ask.json.  Every other key in the file is kept, and the
    old file is copied to .ask.json.bak first.  With "tools": true in the
    config, ask then uses this model for every call.

.PARAMETER Model
    The model to use.  Default qwen2.5:7b.

.PARAMETER NoPull
    Don't download the model; fail if it isn't installed.

.PARAMETER EnableTools
    Also set "tools": true so every ask call can use tools.

.EXAMPLE
    .\ask-setup-tools.ps1
    .\ask-setup-tools.ps1 -Model qwen2.5:14b -EnableTools
    .\ask-setup-tools.ps1 -NoPull
#>

[CmdletBinding()]
param(
    [string] $Model = "qwen2.5:7b",
    [switch] $NoPull,
    [switch] $EnableTools
)

$ErrorActionPreference = "Stop"

function Stop-Setup([string]$message) {
    $Host.UI.WriteErrorLine("ask-setup-tools: $message")
    exit 1
}

# Same location rules as ask.ps1.
$askHome    = if ($env:ASK_HOME) { $env:ASK_HOME } else { $HOME }
$configPath = Join-Path $askHome ".ask.json"

$cfg = [ordered]@{}
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $cfg) { $cfg = [ordered]@{} }
    } catch {
        Stop-Setup "could not parse ${configPath}, not changing it: $($_.Exception.Message)"
    }
}

$ollamaHost = if ($cfg["host"]) { [string]$cfg["host"] } else { "127.0.0.1" }
$ollamaPort = if ($cfg["port_direct"]) { [int]$cfg["port_direct"] } else { 11434 }
$baseUrl    = "http://${ollamaHost}:${ollamaPort}"

function Get-InstalledModels {
    try {
        $tags = Invoke-RestMethod "$baseUrl/api/tags" -TimeoutSec 10
    } catch {
        Stop-Setup "Ollama isn't reachable at $baseUrl. Start it with: ollama serve"
    }
    return @($tags.models | ForEach-Object { $_.name })
}

function Test-HasModel([string[]]$installed) {
    return ($installed -contains $Model) -or ($installed -contains "${Model}:latest")
}

Write-Host "Checking Ollama at $baseUrl ..." -ForegroundColor Cyan
$installed = Get-InstalledModels
Write-Host "[OK] Ollama is running ($($installed.Count) models installed)." -ForegroundColor Green

if (-not (Test-HasModel $installed)) {
    if ($NoPull) { Stop-Setup "$Model is not installed and -NoPull was given." }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Stop-Setup "$Model is not installed and the ollama command isn't on PATH. Pull it from the Ollama app, then rerun."
    }
    Write-Host "Pulling $Model (this can take a few minutes) ..." -ForegroundColor Cyan
    & ollama pull $Model
    if ($LASTEXITCODE -ne 0) { Stop-Setup "ollama pull $Model failed (exit $LASTEXITCODE)." }
    $installed = Get-InstalledModels
    if (-not (Test-HasModel $installed)) { Stop-Setup "$Model still isn't listed after the pull." }
}
Write-Host "[OK] $Model is installed." -ForegroundColor Green

# Ollama reports what a model can do; tools need the "tools" capability.
try {
    $show = Invoke-RestMethod "$baseUrl/api/show" -Method Post -ContentType "application/json" `
        -Body (@{ model = $Model } | ConvertTo-Json) -TimeoutSec 30
    $caps = @($show.capabilities | Where-Object { $_ })
} catch {
    $caps = @()
    Write-Host "[WARN] couldn't read $Model's capabilities: $($_.Exception.Message)" -ForegroundColor Yellow
}
if ($caps.Count -gt 0 -and $caps -notcontains "tools") {
    Write-Host "[WARN] $Model reports no tool support (capabilities: $($caps -join ', '))." -ForegroundColor Yellow
    Write-Host "       Saving it anyway; ask will fall back to the text protocol, which small models often ignore." -ForegroundColor Yellow
} elseif ($caps -contains "tools") {
    Write-Host "[OK] $Model supports native tool calls." -ForegroundColor Green
}

if (Test-Path $configPath) { Copy-Item $configPath "$configPath.bak" -Force }

$cfg["tools_model"] = $Model
if ($EnableTools) { $cfg["tools"] = $true }
$cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath

Write-Host ""
Write-Host "Saved tools_model = '$Model' in $configPath" -ForegroundColor Green
if ($EnableTools) {
    Write-Host "Tools are on for every call (\"tools\": true)." -ForegroundColor Green
} elseif ($cfg["tools"] -ne $true) {
    Write-Host "Tools are still off by default; use ask -Tools ..., or rerun with -EnableTools." -ForegroundColor DarkGray
}
Write-Host "Try: ask what time is it" -ForegroundColor DarkGray
