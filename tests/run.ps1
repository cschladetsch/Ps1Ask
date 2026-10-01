<#
.SYNOPSIS
    Run ask's test suite (Pester 5).

.DESCRIPTION
    Unit.Tests.ps1 tests ask's functions in-process; Integration.Tests.ps1
    runs ask.ps1 as a command against a fake Ollama (MockOllama.ps1). Neither
    needs a real Ollama, and neither touches your ~/.ask.json, history or
    model cache (each test gets its own ASK_HOME).

.EXAMPLE
    ./tests/run.ps1
    ./tests/run.ps1 -Path ./tests/Unit.Tests.ps1 -Detailed
#>
param(
    [string] $Path = $PSScriptRoot,
    [switch] $Detailed
)

$ErrorActionPreference = "Stop"

# Windows ships Pester 3.4, which can't run these tests.
if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -ge [version]"5.5" })) {
    Write-Host "Pester 5.5+ is needed. Install it with:" -ForegroundColor Yellow
    Write-Host "  Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck"
    exit 1
}
Import-Module Pester -MinimumVersion 5.5

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = if ($Detailed) { "Detailed" } else { "Normal" }
Invoke-Pester -Configuration $config
