<#
.SYNOPSIS
    Installs 'ask' to ~/bin and writes ~/.ask.json with sensible defaults.
 
.DESCRIPTION
    1. Copies ask.ps1 and ask-tools.ps1 to the install directory (default: ~/bin)
    2. Adds the directory to user PATH permanently
    3. Adds a global 'ask' function + alias to $PROFILE
    4. Prompts for config values and writes ~/.ask.json
    5. Makes 'ask' available in the current session immediately
 
.PARAMETER Destination
    Directory to install into.  Default: ~/bin
 
.PARAMETER Force
    Overwrite existing files without prompting.
 
.EXAMPLE
    .\install.ps1
    .\install.ps1 -Destination C:\tools
    .\install.ps1 -Force
#>
param(
    [string] $Destination = (Join-Path $HOME "bin"),
    [switch] $Force
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
 
function Prompt-WithDefault([string]$msg, [string]$default) {
    $display = if ($default -ne "") { "$msg [$default]" } else { $msg }
    $ans = Read-Host $display
    if ([string]::IsNullOrWhiteSpace($ans)) { $default } else { $ans.Trim() }
}
 
function Prompt-YN([string]$msg, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
    $ans = Read-Host "$msg $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultYes }
    return $ans -match '^[Yy]'
}
 
# ── Banner ────────────────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  ask installer" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
 
# ── Verify source ─────────────────────────────────────────────────────────────
 
$src = Join-Path $PSScriptRoot "ask.ps1"
if (-not (Test-Path $src)) {
    Write-Error "ask.ps1 not found at $src -- run install.ps1 from the repo root."
    exit 1
}
 
# ── Install directory ─────────────────────────────────────────────────────────
 
if (-not (Test-Path $Destination)) {
    New-Item $Destination -ItemType Directory | Out-Null
    Write-Host "  Created $Destination" -ForegroundColor Cyan
}
 
$dest = Join-Path $Destination "ask.ps1"
if ((Test-Path $dest) -and -not $Force) {
    if (-not (Prompt-YN "  ask.ps1 already exists at $dest. Overwrite?")) {
        Write-Host "  Aborted." -ForegroundColor Yellow; exit 0
    }
}
Copy-Item $src $dest -Force

# The tool loop lives in its own file, loaded by ask.ps1 only when tools are on.
$toolsSrc = Join-Path $PSScriptRoot "ask-tools.ps1"
if (-not (Test-Path $toolsSrc)) {
    Write-Error "ask-tools.ps1 not found at $toolsSrc -- run install.ps1 from the repo root."
    exit 1
}
Copy-Item $toolsSrc (Join-Path $Destination "ask-tools.ps1") -Force

# Stamp commit and install time into the installed copy (shown by ask --version).
$commit = git -C $PSScriptRoot rev-parse --short HEAD 2>$null
if (-not $commit) { $commit = "unknown commit" }
elseif (git -C $PSScriptRoot status --porcelain 2>$null) { $commit += "-dirty" }
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
$text  = [System.IO.File]::ReadAllText($dest)
$text  = $text -replace '(?m)^\$AskCommit\s*=\s*"[^"]*"',    "`$AskCommit    = ""$commit"""
$text  = $text -replace '(?m)^\$AskInstalled\s*=\s*"[^"]*"', "`$AskInstalled = ""$stamp"""
[System.IO.File]::WriteAllText($dest, $text)
Write-Host "  Copied ask.ps1 -> $dest ($commit, $stamp)" -ForegroundColor Green
 
# ── PATH ──────────────────────────────────────────────────────────────────────
 
$userPath  = [Environment]::GetEnvironmentVariable("PATH", "User") ?? ""
$pathParts = $userPath -split ";" | Where-Object { $_ -ne "" }
 
if ($Destination -notin $pathParts) {
    [Environment]::SetEnvironmentVariable("PATH", ($pathParts + $Destination) -join ";", "User")
    Write-Host "  Added $Destination to user PATH." -ForegroundColor Green
} else {
    Write-Host "  $Destination already in PATH." -ForegroundColor DarkGray
}
 
if ($Destination -notin ($env:PATH -split ";")) {
    $env:PATH = "$env:PATH;$Destination"
}
 
# ── $PROFILE alias ────────────────────────────────────────────────────────────
 
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item $profileDir -ItemType Directory | Out-Null }
if (-not (Test-Path $PROFILE))    { New-Item $PROFILE    -ItemType File      | Out-Null }
 
$marker = "# CppAsk"
if (Select-String -Path $PROFILE -Pattern ([regex]::Escape($marker)) -Quiet) {
    Write-Host "  Profile already has ask entry." -ForegroundColor DarkGray
} elseif (Prompt-YN "  Add 'ask' alias to ${PROFILE}?") {
    $snippet = @"
 
$marker
function global:ask { & '$dest' @args }
Set-Alias -Name ask -Value global:ask -Scope Global -Option AllScope -Force
"@
    Add-Content $PROFILE $snippet
    Write-Host "  Added ask to $PROFILE" -ForegroundColor Green
}
 
Invoke-Expression "function global:ask { & '$dest' @args }"
Set-Alias -Name ask -Value global:ask -Scope Global -Option AllScope -Force
 
# ── ~/.ask.json config ────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  Configuration  (~/.ask.json)" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Press Enter to accept the default shown in [brackets]."
Write-Host ""
 
# Existing config supplies the defaults, so re-running the installer keeps
# your settings (and any keys it doesn't prompt for, e.g. history, tools).
$configPath = Join-Path $HOME ".ask.json"
$existing = [ordered]@{}
if (Test-Path $configPath) {
    try {
        $j = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $existing[$p.Name] = $p.Value }
    } catch { }
}
function Get-Existing([string]$key, $fallback) {
    if ($existing.Contains($key) -and $null -ne $existing[$key]) { return [string]$existing[$key] }
    return $fallback
}

# Discover available Ollama models for the prompt hint
$modelHint = Get-Existing "model" "dolphin-llama3:8b"
try {
    $ollamaOut = & ollama list 2>$null | Select-Object -Skip 1
    $models = $ollamaOut | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -ne "" }
    if ($models.Count -gt 0) {
        Write-Host "  Available Ollama models:" -ForegroundColor DarkGray
        $models | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        # Keep the configured model if it's installed; otherwise prefer a
        # reasonably capable one (tool support first), never just the first
        # listed -- that picked gemma2:2b, too small to answer usefully.
        if ($models -notcontains $modelHint) {
            $preferred = @("dolphin-llama3:8b", "qwen2.5-coder:7b", "qwen2.5:7b", "llama3.1:8b",
                           "nous-hermes2:latest", "dolphin-mistral:latest")
            $pick = $preferred | Where-Object { $models -contains $_ } | Select-Object -First 1
            $modelHint = if ($pick) { $pick } else { $models[0] }
        }
    }
} catch {
    Write-Host "  (Could not query ollama list -- enter model name manually)" -ForegroundColor DarkGray
}
 
$cfgModel      = Prompt-WithDefault "  Default model      " $modelHint
$cfgHost       = Prompt-WithDefault "  Ollama host        " (Get-Existing "host" "127.0.0.1")
$cfgPortDirect = Prompt-WithDefault "  Ollama port        " (Get-Existing "port_direct" "11434")
$cfgPortServe  = Prompt-WithDefault "  cppcoder port      " (Get-Existing "port_serve" "8765")
$cfgSystem     = Prompt-WithDefault "  System prompt      " (Get-Existing "system" "")
 
$config = $existing
$config["model"]       = $cfgModel
$config["host"]        = $cfgHost
$config["port_direct"] = [int]$cfgPortDirect
$config["port_serve"]  = [int]$cfgPortServe
$config["system"]      = $cfgSystem
 
$config | ConvertTo-Json | Set-Content $configPath
Write-Host ""
Write-Host "  Wrote $configPath" -ForegroundColor Green
 
# ── Done ──────────────────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  Done. Try it now:" -ForegroundColor Cyan
Write-Host "    ask what is the rule of five"
Write-Host "    ask explain CRTP -Model $cfgModel"
Write-Host "    ask -SetModel qwen2.5-coder:7b"
Write-Host ""
Write-Host "  New shells: restart your terminal or run: . `$PROFILE" -ForegroundColor DarkGray
Write-Host ""