<#
.SYNOPSIS
    Ask a local Ollama model a question from the shell; the reply streams
    to the terminal as rendered Markdown.

.DESCRIPTION
    Sends a question to Ollama's /api/chat (default) or a running cppcoder
    --serve instance.  Config is loaded from ~/.ask.json; any parameter
    passed on the command line overrides the config for that run.

    Quotes are optional, but PowerShell parses the words before ask sees
    them: an apostrophe starts a string, # starts a comment, (...) and $x
    are evaluated, and | ; & < > split or redirect the command.  Quote the
    question (single quotes are safest) when it contains any of those.

.PARAMETER Question
    The question to ask.  Quotes optional -- unquoted words are joined.
    Can also be piped in.

.PARAMETER Model
    On its own (ask -model), print the current model and exit.  Followed
    or preceded by an installed model tag, use that model for this call:
    ask -Model qwen2.5:7b what is CRTP, or ask what is CRTP -Model
    qwen2.5:7b.  Overrides config (both "model" and "tools_model").
    Also accepted as --model to show the current model.

.PARAMETER OllamaHost
    Ollama hostname.  Overrides config.

.PARAMETER Port
    Ollama port.  Overrides config.

.PARAMETER Direct
    Talk straight to Ollama (default: true).  -Direct:$false routes via
    cppcoder --serve on port 8765.

.PARAMETER System
    System prompt prepended to the conversation.  Overrides config.

.PARAMETER NoStream
    Collect the full reply before printing it.

.PARAMETER NoColor
    Print the reply as plain text, without Markdown rendering.

.PARAMETER SetModel
    Save a new default model to ~/.ask.json, then exit.  Other settings in
    the file are left as they are.

.PARAMETER NewChat
    Clear conversation history before asking, then start a fresh thread
    with this question.

.PARAMETER NoHistory
    Ask this one question without reading or writing conversation
    history at all -- a true one-shot, ignoring any existing thread.
    To turn history off permanently, set "history": false in ~/.ask.json.

.PARAMETER ClearHistory
    Wipe conversation history and exit without asking anything.

.PARAMETER Tools
    Give the model tools (fetch_url, open_url, read_file, run_command) for
    this call.  Set "tools": true in ~/.ask.json to make it the default.
    run_command asks y/N before running anything.

.PARAMETER NoTools
    Turn tools off for this call when they're on in config.  Also turns
    off the local "br <url>" shortcut.

.PARAMETER Help
    Print a short usage summary, then exit.  Also accepted as --help
    or -h.  Get-Help ask.ps1 -Full shows this full help.

.PARAMETER Explain
    Ask for a thorough explanation with examples.  Alias: -v.  Also
    accepted as -Verbose or --verbose anywhere in the question.

.PARAMETER Version
    Print the version, commit and install time, then exit.  Also
    accepted as --version.

.PARAMETER Models
    List models available on the Ollama server, then exit.

.PARAMETER Check
    Check that the Ollama server is up and list its models, with * in
    front of the current one, then exit (non-zero if the server is down).
    Also accepted as --check, and run by the ask-check command.

.EXAMPLE
    ask what is 1+2
    ask explain CRTP in modern C++
    ask 'what''s the difference between std::span and std::string_view'
    ask what does PatchApplier do -Model codellama:7b
    ask -model
    ask --check
    ask -SetModel dolphin-8b:latest
    ask br old.reddit.com
    ask -Tools summarise https://example.com
    ask -Tools how much free space is on C:
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Question,

    # A switch, not [string], so a bare `ask -model` can show the current
    # model. The tag for a one-call override is taken from the question's
    # first or last word (see "Model override" below).
    [switch] $Model,
    [string] $OllamaHost  = "",
    [int]    $Port        = 0,
    [switch] $Direct      = $true,
    [string] $System      = "",
    [switch] $NoStream,
    # Kept for compatibility: -Pretty:$false is the same as -NoColor.
    [switch] $Pretty      = $true,
    [switch] $NoColor,
    [string] $SetModel    = "",
    [switch] $NewChat,
    [switch] $NoHistory,
    [switch] $ClearHistory,
    [switch] $Tools,
    [switch] $NoTools,
    [switch] $Version,
    # -v would otherwise prefix-match -Version; an exact alias wins.
    [Alias("v")]
    [switch] $Explain,
    [Alias("h")]
    [switch] $Help,
    [switch] $Models,
    [switch] $Check
)

$ErrorActionPreference = "Stop"

# ── Version ───────────────────────────────────────────────────────────────────
# $AskCommit and $AskInstalled are stamped into the installed copy by
# install.ps1. Bump $AskVersion by hand on a release.

$AskVersion   = "1.2.0"
$AskCommit    = ""
$AskInstalled = ""

if ($Help -or ($Question -contains '--help')) {
    Write-Host @"
ask $AskVersion - ask a local Ollama model a question

Usage:
  ask <question...> [options]      words are joined; no quotes needed
  <text> | ask [options]

Answering:
  -v, --verbose           ask for a thorough explanation
  -Tools                  let the model browse, read files, run commands
  -NoTools                tools off for this call (if on in config)
  -Model <tag>            model to use for this call (installed tag)
  -System <text>          extra system prompt
  -NoStream               buffer the reply before printing
  -NoColor                plain output, no markdown rendering

History:
  -NewChat                clear history, then ask
  -NoHistory              don't read or write history for this call
  -ClearHistory           clear history and exit
  (a thread also starts fresh after "history_idle_minutes" of no questions)

Server:
  -OllamaHost <host>      default 127.0.0.1
  -Port <n>               default 11434
  -Direct:`$false          go via cppcoder --serve (port 8765)

Other:
  br <url>                open a URL in your browser (no model involved)
  -model, --model         show the current model
  -Models                 list models on the server (* = default)
  --check, -Check         is the server up? list models (* = current)
                          (same as the ask-check command)
  -SetModel <tag>         save a new default model
  --version, -Version     version, commit and install time
  --help, -h              this help

Quoting: PowerShell reads the words first. Quote the question if it has
  '  (starts a string)     #  (starts a comment)     `$x or (...) (evaluated)
  | ; & < >  (split or redirect the command)
  e.g.  ask 'what''s a #pragma once'

Tools (off by default; -Tools or "tools": true): fetch_url, open_url,
read_file, run_command. run_command asks y/N first. Set "tools_model" to a
model with native tool support (e.g. qwen2.5:7b) to use it with -Tools.

Config:  ~/.ask.json   (model, tools_model, host, port_direct, port_serve,
                        system, history, history_idle_minutes, tools,
                        confirm_commands, tool_output_chars)
History: ~/.ask_conversation_state.json

Examples:
  ask what is 1+2
  ask what is the rule of five
  ask br old.reddit.com
  ask explain CRTP -v
"@
    return
}

if ($Version -or ($Question -contains '--version')) {
    if ($AskInstalled -ne "") {
        Write-Host "ask $AskVersion ($AskCommit) installed $AskInstalled"
    } else {
        $commit = git -C $PSScriptRoot rev-parse --short HEAD 2>$null
        if ($commit -and (git -C $PSScriptRoot status --porcelain 2>$null)) { $commit += "-dirty" }
        $commit = if ($commit) { $commit } else { "unknown commit" }
        Write-Host "ask $AskVersion ($commit) not installed, running from $PSScriptRoot"
    }
    return
}

function Stop-Ask([string]$message) {
    $Host.UI.WriteErrorLine("ask: $message")
    exit 1
}

# ── Markdown renderer (no external tools) ─────────────────────────────────────
# Line-based, so it can render a streamed reply as each line completes: text
# is buffered only until the next newline. Fenced code is tracked across
# lines in the renderer state.

$ESC        = [char]27
$AnsiReset  = "$ESC[0m"
$AnsiBold   = "$ESC[1m"
$AnsiDim    = "$ESC[2m"
$AnsiCyan   = "$ESC[96m"
$AnsiYellow = "$ESC[93m"
$AnsiGreen  = "$ESC[92m"
$AnsiPink   = "$ESC[95m"

function Format-MdInline([string]$s) {
    # Code spans first, and their contents are left alone.
    $parts = $s -split '(`[^`]+`)'
    $out = foreach ($p in $parts) {
        if ($p -match '^`[^`]+`$') {
            "$AnsiGreen$($p.Substring(1, $p.Length - 2))$AnsiReset"
        } else {
            $p = $p -replace '\*\*([^*]+)\*\*', "$AnsiBold`$1$AnsiReset"
            $p = $p -replace '(?<![\w*])\*([^*\s][^*]*)\*', "$AnsiDim`$1$AnsiReset"
            $p
        }
    }
    return ($out -join '')
}

function New-MdRenderer {
    return @{ InCode = $false; Pending = [System.Text.StringBuilder]::new() }
}

function Write-MdLine($r, [string]$line) {
    $line = $line.TrimEnd("`r")

    if ($line -match '^\s*```(.*)$') {
        if ($r.InCode) {
            $r.InCode = $false
        } else {
            $r.InCode = $true
            $lang = $Matches[1].Trim()
            if ($lang -ne "") { Write-Host "$AnsiDim$lang$AnsiReset" }
        }
        return
    }

    if ($r.InCode) {
        Write-Host "$AnsiGreen$line$AnsiReset"
        return
    }

    if ($line -match '^(#{1,6})\s+(.*)$') {
        $colour = switch ($Matches[1].Length) { 1 { $AnsiCyan } 2 { $AnsiYellow } default { $AnsiPink } }
        Write-Host "$AnsiBold$colour$(Format-MdInline $Matches[2])$AnsiReset"
        return
    }

    if ($line -match '^\s*([-*_])(\s*\1){2,}\s*$') {
        Write-Host "$AnsiDim$('─' * 60)$AnsiReset"
        return
    }

    # List markers are split off before inline formatting, so a "* " bullet
    # isn't taken for italics.
    if ($line -match '^(\s*)[-*+]\s+(.*)$') {
        Write-Host "$($Matches[1])  $AnsiYellow•$AnsiReset $(Format-MdInline $Matches[2])"
        return
    }
    if ($line -match '^(\s*)(\d+)[.)]\s+(.*)$') {
        Write-Host "$($Matches[1])  $AnsiYellow$($Matches[2]).$AnsiReset $(Format-MdInline $Matches[3])"
        return
    }

    Write-Host (Format-MdInline $line)
}

function Add-MdText($r, [string]$text) {
    [void]$r.Pending.Append($text)
    $s  = $r.Pending.ToString()
    $nl = $s.LastIndexOf("`n")
    if ($nl -lt 0) { return }
    [void]$r.Pending.Clear().Append($s.Substring($nl + 1))
    foreach ($l in $s.Substring(0, $nl) -split "`n") { Write-MdLine $r $l }
}

function Complete-Md($r) {
    if ($r.Pending.Length -gt 0) {
        Write-MdLine $r $r.Pending.ToString()
        [void]$r.Pending.Clear()
    }
    $r.InCode = $false
    Write-Host $AnsiReset -NoNewline
}

function Write-Markdown([string]$text) {
    $r = New-MdRenderer
    Add-MdText $r $text
    Complete-Md $r
}

# ── Load ~/.ask.json ──────────────────────────────────────────────────────────

$configPath = Join-Path $HOME ".ask.json"

$defaults = @{
    model                = "dolphin-8b:latest"
    tools_model          = ""      # used instead of "model" when tools are on
    host                 = "127.0.0.1"
    port_direct          = 11434
    port_serve           = 8765
    system               = ""
    history              = $true
    history_idle_minutes = 30      # 0 = threads never expire
    tools                = $false
    confirm_commands     = $true   # y/N before run_command
    tool_output_chars    = 8000
}

if (Test-Path $configPath) {
    try {
        $saved = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($key in @($defaults.Keys)) {
            if ($null -ne $saved.$key) { $defaults[$key] = $saved.$key }
        }
    } catch {
        Write-Warning "Could not parse ${configPath}: $_"
    }
}

function Test-AskFlag($value) { return $value -in @($true, "true", 1) }

# ── Conversation history (~/.ask_conversation_state.json) ─────────────────────
# A flat list of {role, content} turns, most recent last. Capped to the last
# $maxHistoryTurns exchanges (user+assistant pairs) so context doesn't grow
# forever, and ignored once nobody has asked anything for
# "history_idle_minutes", so a question tomorrow doesn't inherit tonight's
# thread. On by default; "history": false in ~/.ask.json turns it off.
# -NoHistory skips reading/writing it for one call; -NewChat clears it before
# this question; -ClearHistory clears it and exits.
#
# Turns go to /api/chat with their proper roles, so the model sees earlier
# questions as already answered. (The original "re-answers every old
# question" bug came from flattening history into an /api/generate prompt.)

$historyPath     = Join-Path $HOME ".ask_conversation_state.json"
$maxHistoryTurns = 20   # exchanges, i.e. 40 messages
$useHistory      = (Test-AskFlag $defaults["history"]) -and -not $NoHistory

function Get-AskHistory {
    if (-not (Test-Path $historyPath)) { return @() }
    $idle = [double]$defaults["history_idle_minutes"]
    if ($idle -gt 0 -and ((Get-Date) - (Get-Item -LiteralPath $historyPath -Force).LastWriteTime).TotalMinutes -gt $idle) {
        return @()
    }
    try {
        $raw = Get-Content $historyPath -Raw | ConvertFrom-Json
        if ($null -eq $raw) { return @() }
        return @($raw)
    } catch {
        Write-Warning "Could not parse ${historyPath}, starting fresh: $_"
        return @()
    }
}

function Set-AskHistory([array]$turns) {
    $maxMessages = $maxHistoryTurns * 2
    if ($turns.Count -gt $maxMessages) {
        $turns = $turns[($turns.Count - $maxMessages)..($turns.Count - 1)]
    }
    ConvertTo-Json -InputObject @($turns) -Depth 5 | Set-Content $historyPath
}

if ($ClearHistory) {
    Set-Content $historyPath "[]"
    Write-Host "Conversation history cleared ($historyPath)" -ForegroundColor Green
    return
}

if ($NewChat) {
    Set-Content $historyPath "[]"
}

# ── Handle -SetModel ──────────────────────────────────────────────────────────
# Only "model" changes; every other key in the file is kept as written.
# (Dumping the in-memory defaults here once switched tools on behind the
# user's back.)

if ($SetModel -ne "") {
    $cfg = [ordered]@{}
    if (Test-Path $configPath) {
        try { $cfg = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable } catch {
            Stop-Ask "Could not parse ${configPath}, not changing it: $_"
        }
        if ($null -eq $cfg) { $cfg = [ordered]@{} }
    }
    $cfg["model"] = $SetModel
    $cfg | ConvertTo-Json | Set-Content $configPath
    Write-Host "Default model set to '$SetModel' in $configPath" -ForegroundColor Green
    return
}

# ── Resolve server (CLI overrides config) ─────────────────────────────────────

$effectiveHost = if ($OllamaHost -ne "") { $OllamaHost } else { $defaults["host"] }
$effectivePort = if ($Port -ne 0) { $Port } elseif ($Direct) { $defaults["port_direct"] } else { $defaults["port_serve"] }
$baseUrl       = "http://${effectiveHost}:${effectivePort}"
$serverName    = if ($Direct) { "Ollama at $baseUrl" } else { "cppcoder at $baseUrl (is cppcoder --serve running?)" }

# ── HTTP (one client for everything) ──────────────────────────────────────────
# Ollama puts the real reason for a 4xx/5xx in a JSON body {"error": "..."};
# that's what gets reported, not just "(500) Internal Server Error".

$Http = [System.Net.Http.HttpClient]::new()
$Http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

function Send-Ollama([string]$path, $body, [switch]$Stream) {
    $method = if ($null -eq $body) { [System.Net.Http.HttpMethod]::Get } else { [System.Net.Http.HttpMethod]::Post }
    $req = [System.Net.Http.HttpRequestMessage]::new($method, "$baseUrl$path")
    if ($null -ne $body) {
        $json = $body | ConvertTo-Json -Depth 20 -Compress
        $req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
    }
    $mode = if ($Stream) { [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead } else { [System.Net.Http.HttpCompletionOption]::ResponseContentRead }
    try {
        $resp = $Http.SendAsync($req, $mode).GetAwaiter().GetResult()
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        throw "Could not reach $serverName -- $($e.Message)"
    }
    if (-not $resp.IsSuccessStatusCode) {
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $detail = $text.Trim()
        try { $j = $text | ConvertFrom-Json -ErrorAction Stop; if ($j.error) { $detail = [string]$j.error } } catch { }
        if ($detail -eq "") { $detail = "$([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
        $resp.Dispose()
        throw "$path failed: $detail"
    }
    return $resp
}

function Invoke-OllamaJson([string]$path, $body = $null) {
    $resp = Send-Ollama $path $body
    try { return ($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json) }
    finally { $resp.Dispose() }
}

# Streams /api/chat, calling $onToken for each piece of content.
function Invoke-OllamaChatStream($body, [scriptblock]$onToken) {
    $resp   = Send-Ollama "/api/chat" $body -Stream
    $reader = [System.IO.StreamReader]::new($resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $obj = $null
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.error) { throw "/api/chat failed: $($obj.error)" }
            $token = $obj.message.content
            if ($token) { & $onToken $token }
            if ($obj.done -eq $true) { break }
        }
    } finally {
        $reader.Dispose()
        $resp.Dispose()
    }
}

# ── Handle -Models ─────────────────────────────────────────────────────────────

if ($Models) {
    try { $tagsResp = Invoke-OllamaJson "/api/tags" } catch { Stop-Ask $_.Exception.Message }
    if (-not $tagsResp.models -or $tagsResp.models.Count -eq 0) {
        Write-Host "No models found at $baseUrl" -ForegroundColor Yellow
        return
    }
    foreach ($m in $tagsResp.models | Sort-Object name) {
        $marker = if ($m.name -eq $defaults["model"]) { "*" } elseif ($m.name -eq $defaults["tools_model"]) { "t" } else { " " }
        $size = if ($m.size) { " ({0:N1} GB)" -f ($m.size / 1GB) } else { "" }
        Write-Host "$marker $($m.name)$size"
    }
    Write-Host ""
    Write-Host "* = default model (ask -SetModel <name>), t = tools_model" -ForegroundColor DarkGray
    return
}

# ── Handle --check / -Check (also the ask-check command) ──────────────────────
# Is the server up, what's installed, and which model is current (*). Exits
# non-zero when the server can't be reached, so scripts can test it.

if ($Check -or ($Question -contains '--check')) {
    Write-Host "Checking $serverName..." -ForegroundColor Cyan
    try {
        $tagsResp = Invoke-OllamaJson "/api/tags"
    } catch {
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        if ($Direct) {
            Write-Host "Try restarting it: Stop-Process -Name 'ollama' -Force; ollama serve" -ForegroundColor Yellow
        }
        exit 1
    }
    Write-Host "[OK] Server is running." -ForegroundColor Green
    $current = $defaults["model"]
    $names   = @($tagsResp.models | ForEach-Object { $_.name } | Sort-Object)
    if ($names.Count -eq 0) {
        Write-Host "No models installed. Try: ollama pull $current" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "Available models:"
    foreach ($n in $names) {
        if ($n -eq $current) { Write-Host " * $n" -ForegroundColor Green } else { Write-Host " - $n" }
    }
    if ($names -notcontains $current) {
        Write-Host "[WARN] Current model '$current' is not installed. Try: ollama pull $current" -ForegroundColor Yellow
    }
    exit 0
}

# ── --verbose / -Verbose ──────────────────────────────────────────────────────
# -Verbose is PowerShell's common parameter (from CmdletBinding); --verbose
# arrives as a plain word in $Question, so strip it from there.

$verboseMode = $Explain -or $PSBoundParameters.ContainsKey('Verbose') -or ($Question -contains '--verbose')
$Question    = @($Question | Where-Object { $_ -and $_ -ne '--verbose' })

# ── Model override / show current model ───────────────────────────────────────
# -Model is a switch so that `ask -model` on its own can show the current
# model. With a question, the override tag is its first or last word (where
# PowerShell leaves the word that followed -Model), checked against the
# installed models; a word with a ":" counts if the server can't be asked.

$showModel     = ($Model -and $Question.Count -eq 0) -or ($Question.Count -eq 1 -and $Question[0] -eq '--model')
$modelOverride = ""

if ($showModel) {
    Write-Host $defaults["model"]
    if ($defaults["tools_model"] -ne "") {
        Write-Host "tools_model: $($defaults["tools_model"])" -ForegroundColor DarkGray
    }
    return
}

if ($Model) {
    $installed = @()
    try { $installed = @((Invoke-OllamaJson "/api/tags").models | ForEach-Object { $_.name }) } catch { }
    function Test-ModelTag([string]$w) {
        if ($installed.Count -eq 0) { return $w -match '^[\w./-]+:[\w.-]+$' }
        return ($installed -contains $w) -or ($installed -contains "${w}:latest")
    }
    $pick = -1
    if (Test-ModelTag $Question[0]) { $pick = 0 }
    elseif ($Question.Count -gt 1 -and (Test-ModelTag $Question[-1])) { $pick = $Question.Count - 1 }
    if ($pick -lt 0) {
        Stop-Ask ("-Model needs an installed model tag right before or after the question " +
                  "(neither '$($Question[0])' nor '$($Question[-1])' is one). See: ask -Models")
    }
    $modelOverride = $Question[$pick]
    if ($installed -notcontains $modelOverride -and $installed -contains "${modelOverride}:latest") {
        $modelOverride = "${modelOverride}:latest"
    }
    $Question = @(for ($i = 0; $i -lt $Question.Count; $i++) { if ($i -ne $pick) { $Question[$i] } })
}

# ── Require a question ────────────────────────────────────────────────────────

if (-not $Question) {
    Stop-Ask "No question provided. Usage: ask what is the rule of five"
}

$questionText = $Question -join " "

# ── "br/open <url>" is handled here, not by the model ─────────────────────────
# Small models refuse to browse even with tools offered, and there's nothing to
# decide: just open it. -NoTools turns this off too.

function Resolve-AskUrl([string]$u) {
    $u = $u.Trim()
    if ($u -notmatch '^[a-z][a-z0-9+.-]*://') { $u = "https://$u" }
    return $u
}

if (-not $NoTools -and $questionText -match '^\s*(?:br|open|go\s+to|goto|visit)\s+(\S+)\s*$') {
    $target = $Matches[1]
    if ($target -match '^(?:[a-z][a-z0-9+.-]*://)?(?:localhost|[\w-]+(?:\.[\w-]+)+)(?::\d+)?(?:[/?#]\S*)?$') {
        $u = Resolve-AskUrl $target
        Write-Host "  > open $u" -ForegroundColor DarkGray
        Start-Process $u
        return
    }
}

# ── Model and capabilities ────────────────────────────────────────────────────
# Ollama reports capabilities (completion, tools, vision, ...) from /api/show;
# /api/tags doesn't list them and there is no "chat" capability. (An earlier
# check for "chat" in /api/tags silently sent every model down the
# /api/generate path.) Results are cached for a day in ~/.ask_model_cache.json
# so a normal question costs one request, not two.

$toolsOn        = -not $NoTools -and ($Tools -or (Test-AskFlag $defaults["tools"]))
$effectiveModel = if ($modelOverride -ne "") { $modelOverride }
                  elseif ($toolsOn -and $defaults["tools_model"] -ne "") { $defaults["tools_model"] }
                  else { $defaults["model"] }

$capsCachePath = Join-Path $HOME ".ask_model_cache.json"
$capsCacheKey  = "$baseUrl|$effectiveModel"
$capsTtlSecs   = 24 * 3600

function Read-CapsCache {
    if (-not (Test-Path $capsCachePath)) { return @{} }
    try { $c = Get-Content $capsCachePath -Raw | ConvertFrom-Json -AsHashtable; if ($c) { return $c } } catch { }
    return @{}
}

function Remove-CachedCaps {
    $cache = Read-CapsCache
    if ($cache.ContainsKey($capsCacheKey)) {
        $cache.Remove($capsCacheKey)
        try { $cache | ConvertTo-Json -Depth 5 | Set-Content $capsCachePath } catch { }
    }
}

function Get-ModelCaps {
    $now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cache = Read-CapsCache
    $hit   = $cache[$capsCacheKey]
    if ($hit -and ($now - [long]$hit["at"]) -lt $capsTtlSecs) { return @($hit["caps"]) }

    try {
        $show = Invoke-OllamaJson "/api/show" @{ model = $effectiveModel }
    } catch {
        if ($_.Exception.Message -match 'not found') {
            Stop-Ask "Model '$effectiveModel' not found on $baseUrl. See: ask -Models"
        }
        return @()   # unreachable, or a proxy without /api/show: the request will report it
    }
    $caps = @($show.capabilities | Where-Object { $_ })
    $cache[$capsCacheKey] = @{ caps = $caps; at = $now }
    try { $cache | ConvertTo-Json -Depth 5 | Set-Content $capsCachePath } catch { }
    return $caps
}

$modelCaps = @(Get-ModelCaps)
if ($modelCaps.Count -gt 0 -and $modelCaps -notcontains "completion") {
    Stop-Ask "Model '$effectiveModel' can't generate text (capabilities: $($modelCaps -join ', '))."
}

$nativeTools = $toolsOn -and ($modelCaps -contains "tools")
if ($toolsOn -and $modelCaps.Count -gt 0 -and -not $nativeTools) {
    Write-Host ("  note: $effectiveModel has no native tool support, so tool use will be unreliable. " +
                "Set ""tools_model"" in ~/.ask.json to one that does (e.g. qwen2.5:7b).") -ForegroundColor DarkGray
}

# ── System prompt ─────────────────────────────────────────────────────────────
# No built-in system prompt: the model's own style (Markdown, examples) is
# what makes ask useful. A day of terse-mode prompt rules and worked examples
# only made small models worse. Only -v and -Tools add a line.

$verboseRule = "Explain thoroughly, with code examples where useful."
$toolRule    = "You have tools: you can fetch web pages, open URLs in the user's browser, read " +
               "local files and run PowerShell commands. When a request needs one (browse, open, " +
               "fetch, look up, read, run, check something on this machine), use a tool instead " +
               "of saying you can't, then answer from its result."

$userSystem = if ($System -ne "") { $System } else { $defaults["system"] }
$sysParts = @()
if ($userSystem -ne "") { $sysParts += $userSystem }
if ($verboseMode)       { $sysParts += $verboseRule }
if ($toolsOn)           { $sysParts += $toolRule }
$effectiveSystem = $sysParts -join "`n`n"

# ── Build messages ────────────────────────────────────────────────────────────

$priorTurns = if ($useHistory) { @(Get-AskHistory) } else { @() }

# Re-asking a question means the earlier answer wasn't good enough. Drop
# earlier exchanges with the same question, or small models just copy them.
$normQ = ($questionText -replace '\s+', ' ').Trim().ToLowerInvariant()
$kept  = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $priorTurns.Count; $i++) {
    $t = $priorTurns[$i]
    if ($t.role -eq "user" -and (([string]$t.content -replace '\s+', ' ').Trim().ToLowerInvariant() -eq $normQ)) {
        if ($i + 1 -lt $priorTurns.Count -and $priorTurns[$i + 1].role -eq "assistant") { $i++ }
        continue
    }
    $kept.Add($t)
}
$priorTurns = @($kept)

$messages = [System.Collections.Generic.List[object]]::new()
if ($effectiveSystem -ne "") { $messages.Add(@{ role = "system"; content = $effectiveSystem }) }
foreach ($turn in $priorTurns) { $messages.Add(@{ role = $turn.role; content = $turn.content }) }
$messages.Add(@{ role = "user"; content = $questionText })

$render = $Pretty -and -not $NoColor

function Save-Exchange([string]$answer) {
    if ($useHistory -and $answer.Trim() -ne "") {
        Set-AskHistory (@($priorTurns) + @(
            @{ role = "user";      content = $questionText },
            @{ role = "assistant"; content = $answer }
        ))
    }
}

function Stop-AskRequest([string]$message) {
    if ($message -match 'not found') { Remove-CachedCaps }
    Stop-Ask $message
}

# ── Tool mode ─────────────────────────────────────────────────────────────────
# The agent loop lives in ask-tools.ps1 and is only loaded when tools are on.

if ($toolsOn) {
    $toolsScript = Join-Path $PSScriptRoot "ask-tools.ps1"
    if (-not (Test-Path $toolsScript)) { Stop-Ask "Tools need ask-tools.ps1 next to ask.ps1 (re-run install.ps1)." }
    . $toolsScript

    try {
        $fullText = Invoke-AskToolLoop -Messages $messages -Native:$nativeTools
    } catch {
        Stop-AskRequest $_.Exception.Message
    }
    if ($render) { Write-Markdown $fullText } else { Write-Host $fullText }
    if ($fullText -notmatch '^\(no answer') { Save-Exchange $fullText }
    return
}

# ── Plain question: stream the reply ──────────────────────────────────────────

$body = @{
    model    = $effectiveModel
    messages = $messages
    stream   = -not $NoStream.IsPresent
}

$collected = [System.Text.StringBuilder]::new()
try {
    if ($NoStream) {
        $resp = Invoke-OllamaJson "/api/chat" $body
        [void]$collected.Append([string]$resp.message.content)
        if ($render) { Write-Markdown $collected.ToString() } else { Write-Host $collected.ToString() }
    } elseif ($render) {
        $md = New-MdRenderer
        Invoke-OllamaChatStream $body { param($tok) [void]$collected.Append($tok); Add-MdText $md $tok }
        Complete-Md $md
    } else {
        Invoke-OllamaChatStream $body { param($tok) [void]$collected.Append($tok); Write-Host -NoNewline $tok }
        Write-Host ""
    }
} catch {
    Stop-AskRequest $_.Exception.Message
}

Save-Exchange $collected.ToString()
