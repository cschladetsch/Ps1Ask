<#
.SYNOPSIS
    Run ask's Pester tests.

.DESCRIPTION
    Wraps Invoke-Pester over .\tests (next to this script).  Exits non-zero
    when any test fails, so it can be used from scripts and hooks.  Needs
    Pester 5 or later.

.PARAMETER Name
    Only run tests whose full name matches this wildcard, e.g.
    ask-tests.ps1 write_file   or   ask-tests.ps1 "fact detection".

.PARAMETER File
    Only run test files whose name matches this wildcard, e.g. fs, Unit,
    Integration.  "fs" matches ask-fs-tools.Tests.ps1.

.PARAMETER Quiet
    Print only failures and the summary.

.PARAMETER Detailed
    Print every test (the default shows one line per Describe block).

.EXAMPLE
    .\ask-tests.ps1
    .\ask-tests.ps1 -File fs -Detailed
    .\ask-tests.ps1 read_file
    .\ask-tests.ps1 -File Unit -Quiet
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Name = "",
    [string] $File = "",
    [switch] $Quiet,
    [switch] $Detailed
)

$ErrorActionPreference = "Stop"

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    $have = if ($pester) { "found $($pester.Version)" } else { "not installed" }
    $Host.UI.WriteErrorLine("ask-tests: Pester 5+ is required ($have). Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck")
    exit 2
}
Import-Module Pester -MinimumVersion 5.0.0

$testDir = Join-Path $PSScriptRoot "tests"
if (-not (Test-Path $testDir)) {
    $Host.UI.WriteErrorLine("ask-tests: no tests folder at $testDir")
    exit 2
}

$paths = if ($File -ne "") {
    @(Get-ChildItem $testDir -Filter "*.Tests.ps1" | Where-Object { $_.Name -like "*$File*" } | ForEach-Object FullName)
} else {
    @($testDir)
}
if ($paths.Count -eq 0) {
    $Host.UI.WriteErrorLine("ask-tests: no test file in $testDir matches '*$File*'")
    exit 2
}

$cfg = New-PesterConfiguration
$cfg.Run.Path     = $paths
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = if ($Quiet) { "Minimal" } elseif ($Detailed) { "Detailed" } else { "Normal" }
if ($Name -ne "") { $cfg.Filter.FullName = "*$Name*" }

# Tests use a scratch ASK_HOME; make sure a leftover one from this shell
# doesn't leak in, and put it back afterwards.
$savedHome = $env:ASK_HOME
Remove-Item Env:ASK_HOME -ErrorAction SilentlyContinue
try {
    $result = Invoke-Pester -Configuration $cfg
} finally {
    if ($null -ne $savedHome) { $env:ASK_HOME = $savedHome }
}

if ($result.FailedCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    exit 1
}
exit 0
