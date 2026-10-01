<#
.SYNOPSIS
    Check the Ollama server and list its models, with * in front of the
    current one.  Same as: ask --check

.DESCRIPTION
    Thin wrapper over ask.ps1 -Check, so there is one implementation.
    Any ask server options pass through, e.g. ask-check -Port 11435.
#>
& (Join-Path $PSScriptRoot "ask.ps1") -Check @args
exit $LASTEXITCODE
