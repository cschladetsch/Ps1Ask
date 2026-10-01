<#
.SYNOPSIS
    Ask the local LLM a one-shot question, streaming the reply to stdout.

.DESCRIPTION
    Sends a question to Ollama's /api/chat (default) or a running cppcoder
    --serve instance.  Config is loaded from ~/.config/ask/config.json; any parameter
    passed on the command line overrides the config for that run.

.PARAMETER Question
    The question to ask.  Quotes optional -- unquoted words are joined.
    Can also be piped in.

.PARAMETER Model
    Ollama model tag.  Overrides config.

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
    Collect full reply before printing.

.PARAMETER SetModel
    Persist a new default model to ~/.config/ask/config.json, then exit.
    Example: ask -SetModel qwen2.5-coder:7b

.PARAMETER NewChat
    Clear conversation history before asking, then start a fresh thread
    with this question.

.PARAMETER NoHistory
    Ask this one question without reading or writing conversation
    history at all -- a true one-shot, ignoring any existing thread.
    To turn history off permanently, set "history": false in ~/.ask.json.

.PARAMETER ClearHistory
    Wipe conversation history and exit without asking anything.

.PARAMETER Verbose
    Ask for a thorough explanation with examples.  Also accepted as
    --verbose anywhere in the question.

.PARAMETER Tools
    Give the model tools (fetch_url, open_url, read_file, run_command) for
    this call.  Set "tools": true in ~/.ask.json to make it the default.
    Commands run without confirmation.

.PARAMETER NoTools
    Turn tools off for this call when they're on in config.

.PARAMETER Help
    Print a short usage summary, then exit.  Also accepted as --help
    or -h.  Get-Help ask.ps1 -Full shows this full help.

.PARAMETER Explain
    Same as --verbose: ask for a thorough explanation.  Alias: -v.

.PARAMETER Version
    Print the version, commit and install time, then exit.  Also
    accepted as --version.

.PARAMETER Models
    List models available on the Ollama server, then exit.

.EXAMPLE
    ask what is 1+2
    ask explain CRTP in modern C++
    ask what does PatchApplier do -Model codellama:7b
    ask -SetModel dolphin-8b:latest
    ask br old.reddit.com
    ask -Tools summarise https://example.com
    ask -Tools how much free space is on C:
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Question,

    [string] $Model       = "",
    [string] $OllamaHost  = "",
    [int]    $Port        = 0,
    [switch] $Direct      = $true,
    [string] $System      = "",
    [switch] $NoStream,
    [switch] $Pretty = $true,
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
    [switch] $Models
)

$ErrorActionPreference = "Stop"

# ── Version ───────────────────────────────────────────────────────────────────
# $AskCommit and $AskInstalled are stamped into the installed copy by
# install.ps1. Bump $AskVersion by hand on a release.

$AskVersion   = "1.1.0"
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
  -Model <tag>            model to use (default from config)
  -System <text>          extra system prompt
  -NoStream               buffer the reply before printing
  -NoColor                plain output, no markdown colouring

History:
  -NewChat                clear history, then ask
  -NoHistory              don't read or write history for this call
  -ClearHistory           clear history and exit

Server:
  -OllamaHost <host>      default 127.0.0.1
  -Port <n>               default 11434
  -Direct:`$false          go via cppcoder --serve (port 8765)

Other:
  -Models                 list models on the server (* = default)
  -SetModel <tag>         save a new default model
  --version, -Version     version, commit and install time
  --help, -h              this help

Tools (off by default; -Tools or "tools": true): fetch_url, open_url,
read_file, run_command. Commands run without confirmation.

Config:  ~/.ask.json   (model, host, port_direct, port_serve, system,
                        history, tools, tool_output_chars)
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

# ── Markdown renderer (no external tools) ─────────────────────────────────────

function Write-Markdown([string]$text) {
    $ESC = [char]27
    $reset   = "$ESC[0m"
    $bold    = "$ESC[1m"
    $dim     = "$ESC[2m"
    $cyan    = "$ESC[96m"
    $yellow  = "$ESC[93m"
    $green   = "$ESC[92m"
    $magenta = "$ESC[95m"

    $inCode = $false
    $codeLang = ""

    foreach ($line in $text -split "`n") {
        if ($line -match '^```(.*)$') {
            if ($inCode) {
                $inCode = $false
                Write-Host "${reset}"
            } else {
                $inCode = $true
                $codeLang = $Matches[1].Trim()
                Write-Host "${dim}${codeLang}${reset}" -ForegroundColor DarkGray
            }
            continue
        }

        if ($inCode) {
            Write-Host "${green}${line}${reset}"
            continue
        }

        # Headers
        if ($line -match '^(#{1,6})\s+(.*)') {
            $level = $Matches[1].Length
            $heading = $Matches[2]
            $colour = switch ($level) {
                1 { $cyan }
                2 { $yellow }
                default { $magenta }
            }
            Write-Host "${bold}${colour}${heading}${reset}"
            continue
        }

        # Horizontal rule
        if ($line -match '^---+$') {
            Write-Host "${dim}$('─' * 60)${reset}"
            continue
        }

        # Inline: bold, italic, inline code -- simple regex replace with ANSI
        $out = $line
        $out = $out -replace '`([^`]+)`',           "${green}`$1${reset}"
        $out = $out -replace '\*\*([^*]+)\*\*',      "${bold}`$1${reset}"
        $out = $out -replace '\*([^*]+)\*',           "${dim}`$1${reset}"

        # Bullet points
        if ($out -match '^\s*[-*]\s+(.*)') {
            Write-Host "  ${yellow}•${reset} $($out -replace '^\s*[-*]\s+','')"
            continue
        }

        # Numbered list
        if ($out -match '^\s*(\d+)\.\s+(.*)') {
            Write-Host "  ${yellow}$($Matches[1]).${reset} $($Matches[2])"
            continue
        }

        Write-Host $out
    }
    Write-Host $reset -NoNewline
}

# ── Load ~/.config/ask/config.json ──────────────────────────────────────────────────────────

$configPath = Join-Path $HOME ".ask.json"

$defaults = @{
    model      = "dolphin-8b:latest"
    host       = "127.0.0.1"
    port_direct = 11434
    port_serve  = 8765
    system     = ""
    history    = $true
    tools      = $false
    tool_output_chars = 8000
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

# ── Conversation history (~/.ask_conversation_state.json) ─────────────────────
# A flat list of {role, content} turns, most recent last. Capped to the last
# $maxHistoryTurns exchanges (user+assistant pairs) so context doesn't grow
# forever. On by default; "history": false in ~/.ask.json turns it off.
# -NoHistory skips reading/writing it for one call; -NewChat clears it before
# this question; -ClearHistory clears it and exits.
#
# Turns go to /api/chat with their proper roles, so the model sees earlier
# questions as already answered. (The original "re-answers every old
# question" bug came from flattening history into an /api/generate prompt.)

$historyPath     = Join-Path $HOME ".ask_conversation_state.json"
$maxHistoryTurns = 20   # exchanges, i.e. 40 messages
$useHistory      = ($defaults["history"] -in @($true, "true", 1)) -and -not $NoHistory

# No built-in system prompt: the model's own style (Markdown, examples) is
# what makes ask useful. A day of terse-mode prompt rules and worked examples
# only made small models worse. Only -v and -Tools add a line.
$verboseRule = "Explain thoroughly, with code examples where useful."
$toolRule    = "You have tools: you can fetch web pages, open URLs in the user's browser, read " +
               "local files and run PowerShell commands. When a request needs one (browse, open, " +
               "fetch, look up, read, run, check something on this machine), use a tool instead " +
               "of saying you can't, then answer from its result."

function Get-AskHistory {
    if (-not (Test-Path $historyPath)) { return @() }
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
    $turns | ConvertTo-Json -Depth 5 | Set-Content $historyPath
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

if ($SetModel -ne "") {
    $defaults["model"] = $SetModel
    $cfgDir = Split-Path $configPath -Parent
    if (-not (Test-Path $cfgDir)) { New-Item $cfgDir -ItemType Directory | Out-Null }
    $defaults | ConvertTo-Json | Set-Content $configPath
    Write-Host "Default model set to '$SetModel' in $configPath" -ForegroundColor Green
    return
}

# ── Handle -Models ─────────────────────────────────────────────────────────────

if ($Models) {
    $listHost = if ($OllamaHost -ne "") { $OllamaHost } else { $defaults["host"] }
    $listPort = if ($Port -ne 0) { $Port } elseif ($Direct) { $defaults["port_direct"] } else { $defaults["port_serve"] }
    $listUrl  = "http://${listHost}:${listPort}/api/tags"
    try {
        $tagsResp = Invoke-RestMethod $listUrl -ErrorAction Stop
        if (-not $tagsResp.models -or $tagsResp.models.Count -eq 0) {
            Write-Host "No models found at $listUrl" -ForegroundColor Yellow
            return
        }
        $current = $defaults["model"]
        foreach ($m in $tagsResp.models | Sort-Object name) {
            $marker = if ($m.name -eq $current) { "*" } else { " " }
            $size = if ($m.size) { " ({0:N1} GB)" -f ($m.size / 1GB) } else { "" }
            Write-Host "$marker $($m.name)$size"
        }
        Write-Host ""
        Write-Host "* = current default (change with: ask -SetModel <name>)" -ForegroundColor DarkGray
    } catch {
        Write-Error "Could not reach $listUrl`n$($_.Exception.Message)"
        exit 1
    }
    return
}

# ── --verbose / -Verbose ──────────────────────────────────────────────────────
# -Verbose is PowerShell's common parameter (from CmdletBinding); --verbose
# arrives as a plain word in $Question, so strip it from there.

$verboseMode = $Explain -or $PSBoundParameters.ContainsKey('Verbose') -or ($Question -contains '--verbose')
$Question    = @($Question | Where-Object { $_ -ne '--verbose' })

# ── Require a question ────────────────────────────────────────────────────────

if (-not $Question) {
    Write-Error "No question provided. Usage: ask what is the rule of five"
    exit 1
}

# ── HTTP error detail ─────────────────────────────────────────────────────────
# Ollama puts the real reason for a 4xx/5xx in a JSON body {"error": "..."};
# surface it instead of just "(500) Internal Server Error".

function Get-HttpErrorDetail($err) {
    $body = $null
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
        $body = $err.ErrorDetails.Message
    } elseif ($err.Exception.Response -and $err.Exception.Response -is [System.Net.HttpWebResponse]) {
        try {
            $sr = [System.IO.StreamReader]::new($err.Exception.Response.GetResponseStream())
            $body = $sr.ReadToEnd(); $sr.Close()
        } catch { }
    }
    if ($body) {
        try { $j = $body | ConvertFrom-Json -ErrorAction Stop; if ($j.error) { return [string]$j.error } } catch { }
        return $body.Trim()
    }
    return $err.Exception.Message
}

# ── Resolve effective settings (CLI overrides config) ─────────────────────────

$effectiveModel  = if ($Model      -ne "") { $Model     } else { $defaults["model"]  }
$effectiveHost   = if ($OllamaHost -ne "") { $OllamaHost} else { $defaults["host"]   }
$userSystem      = if ($System     -ne "") { $System    } else { $defaults["system"] }

$effectivePort = if ($Port -ne 0) {
    $Port
} elseif ($Direct) {
    $defaults["port_direct"]
} else {
    $defaults["port_serve"]
}

$baseUrl = "http://${effectiveHost}:${effectivePort}"

# ── Model capabilities (/api/show) ────────────────────────────────────────────
# Ollama reports capabilities such as completion, tools, vision, embedding --
# there is no "chat" capability, and /api/tags doesn't list capabilities at
# all. (An earlier check for "chat" in /api/tags silently sent every model
# down the /api/generate path.) /api/chat works for any completion model, so
# it's always used; /api/generate remains only as dead-simple fallback code.

$useChat   = $true
$modelCaps = @()
try {
    $showBody  = @{ model = $effectiveModel } | ConvertTo-Json -Compress
    $show      = Invoke-RestMethod "$baseUrl/api/show" -Method Post -Body $showBody -ContentType "application/json" -ErrorAction Stop
    $modelCaps = @($show.capabilities)
} catch {
    $detail = Get-HttpErrorDetail $_
    if ($detail -match 'not found') {
        Write-Error "Model '$effectiveModel' not found on $baseUrl. See: ask -Models"
        exit 1
    }
    # Server unreachable or old Ollama without /api/show -- carry on, let the request report it.
}
if ($modelCaps.Count -gt 0 -and $modelCaps -notcontains "completion") {
    Write-Error "Model '$effectiveModel' can't generate text (capabilities: $($modelCaps -join ', '))."
    exit 1
}

$url = if ($useChat) { "$baseUrl/api/chat" } else { "$baseUrl/api/generate" }

# Native tool calling if the model advertises it, otherwise a plain-text
# TOOL {...} protocol described in the system prompt.
$toolsOn     = $useChat -and -not $NoTools -and ($Tools -or ($defaults["tools"] -in @($true, "true", 1)))
$nativeTools = $toolsOn -and ($modelCaps -contains "tools")

$sysParts = @()
if ($userSystem -ne "") { $sysParts += $userSystem }
if ($verboseMode)       { $sysParts += $verboseRule }
if ($toolsOn)           { $sysParts += $toolRule }
$effectiveSystem = $sysParts -join "`n`n"

# ── Build request ─────────────────────────────────────────────────────────────

$questionText = $Question -join " "
$sentText     = $questionText

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

if ($useChat) {
    $messages = @()
    if ($effectiveSystem -ne "") {
        $messages += @{ role = "system"; content = $effectiveSystem }
    }
    foreach ($turn in $priorTurns) {
        $messages += @{ role = $turn.role; content = $turn.content }
    }
    $messages += @{ role = "user"; content = $sentText }
    $body = @{
        model    = $effectiveModel
        messages = $messages
        stream   = -not $NoStream.IsPresent
    } | ConvertTo-Json -Depth 5 -Compress
} else {
    $historyText = ($priorTurns | ForEach-Object {
        $label = if ($_.role -eq "assistant") { "Assistant" } else { "User" }
        "${label}: $($_.content)"
    }) -join "`n"
    $promptParts = @()
    if ($effectiveSystem -ne "") { $promptParts += $effectiveSystem }
    if ($historyText -ne "") {
        $promptParts += $historyText
        $promptParts += "User: $sentText"
        $promptParts += "Assistant:"
    } else {
        $promptParts += $sentText
    }
    $prompt = $promptParts -join "`n"
    $body = @{
        model  = $effectiveModel
        prompt = $prompt
        stream = -not $NoStream.IsPresent
    } | ConvertTo-Json -Depth 5 -Compress
}

# ── Tool mode: non-streaming agent loop ───────────────────────────────────────
# The model may call fetch_url, open_url, read_file or run_command; results go
# back in and it loops until it produces a plain answer. Commands run without
# confirmation. Only the question and the final answer are saved to history,
# not the tool traffic.

function Limit-Text([string]$text) {
    $max = [int]$defaults["tool_output_chars"]
    if ($text.Length -gt $max) { return $text.Substring(0, $max) + "`n... [truncated]" }
    return $text
}

function ConvertFrom-Html([string]$html) {
    $t = $html -replace '(?is)<(script|style|noscript|svg|head)\b[^>]*>.*?</\1>', ' '
    $t = $t -replace '(?i)<(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>', "`n"
    $t = $t -replace '<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '[ \t ]+', ' '
    $t = $t -replace '\s*\n\s*', "`n"
    return $t.Trim()
}

function Resolve-AskUrl([string]$u) {
    $u = $u.Trim()
    if ($u -notmatch '^[a-z][a-z0-9+.-]*://') { $u = "https://$u" }
    return $u
}

function Invoke-AskTool([string]$name, $toolArgs) {
    try {
        switch ($name) {
            "fetch_url" {
                $u = Resolve-AskUrl ([string]$toolArgs.url)
                Write-Host "  > fetch $u" -ForegroundColor DarkGray
                $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
                $r = Invoke-WebRequest -Uri $u -UseBasicParsing -UserAgent $ua -TimeoutSec 30 -ErrorAction Stop
                $body = [string]$r.Content
                if ($body -match '(?i)<html|<body|<div') { $body = ConvertFrom-Html $body }
                return Limit-Text $body
            }
            "open_url" {
                $u = Resolve-AskUrl ([string]$toolArgs.url)
                Write-Host "  > open $u" -ForegroundColor DarkGray
                Start-Process $u
                return "Opened $u in the user's default browser."
            }
            "read_file" {
                $path = [string]$toolArgs.path
                if ($path.StartsWith("~")) { $path = Join-Path $HOME $path.Substring(1).TrimStart('/', '\') }
                Write-Host "  > read $path" -ForegroundColor DarkGray
                return Limit-Text (Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
            }
            "run_command" {
                $cmd = [string]$toolArgs.command
                Write-Host "  > run: $cmd" -ForegroundColor DarkGray
                $shell = (Get-Process -Id $PID).Path
                $out = & $shell -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
                return Limit-Text ("exit code: $LASTEXITCODE`n" + $out)
            }
            default { return "Unknown tool '$name'." }
        }
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}

function Show-Answer([string]$text) {
    if ($Pretty -and -not $NoColor) {
        $batCmd = Get-Command bat -ErrorAction SilentlyContinue
        if ($batCmd) {
            $tmp = [System.IO.Path]::GetTempFileName() + ".md"
            [System.IO.File]::WriteAllText($tmp, $text)
            bat --language=markdown --style=plain --color=always --paging=never $tmp
            Remove-Item $tmp -ErrorAction SilentlyContinue
        } else {
            Write-Markdown $text
        }
    } else {
        Write-Host $text
    }
}

$askToolNames = @("fetch_url", "open_url", "read_file", "run_command")

function Find-AskToolCall([string]$text) {
    # 1. Any JSON object (one level of nesting) whose "name" is a known tool.
    foreach ($m in [regex]::Matches($text, '\{(?:[^{}]|\{[^{}]*\})*\}')) {
        $o = $null
        try { $o = $m.Value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($o.name -and ($askToolNames -contains $o.name)) {
            return [pscustomobject]@{ name = $o.name; arguments = $o.arguments }
        }
    }
    # 2. tool_name {args} / tool_name({args})
    $pattern = '\b(' + ($askToolNames -join '|') + ')\b\s*\(?\s*(\{[^{}]*\})'
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) {
        try {
            $a = $m.Groups[2].Value | ConvertFrom-Json -ErrorAction Stop
            return [pscustomobject]@{ name = $m.Groups[1].Value; arguments = $a }
        } catch { }
    }
    return $null
}

# ── "br/open <url>" is handled here, not by the model ─────────────────────────
# Small models refuse to browse even with tools offered, and there's nothing to
# decide: just open it. -NoTools turns this off too.

if (-not $NoTools -and $questionText -match '^\s*(?:br|open|go\s+to|goto|visit)\s+(\S+)\s*$') {
    $target = $Matches[1]
    if ($target -match '^(?:[a-z][a-z0-9+.-]*://)?(?:localhost|[\w-]+(?:\.[\w-]+)+)(?::\d+)?(?:[/?#]\S*)?$') {
        $u = Resolve-AskUrl $target
        Write-Host "  > open $u" -ForegroundColor DarkGray
        Start-Process $u
        return
    }
}

if ($toolsOn) {
    $toolSpecs = @(
        @{ name = "fetch_url";   arg = "url";     desc = "Download a web page and return its text, to read, check or summarise it." },
        @{ name = "open_url";    arg = "url";     desc = "Open a URL in the user's web browser. Use when asked to open, browse, show or go to a site." },
        @{ name = "read_file";   arg = "path";    desc = "Return the contents of a local text file." },
        @{ name = "run_command"; arg = "command"; desc = "Run a PowerShell command on the user's Windows machine and return its output." }
    )

    $chatMessages = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $messages) { $chatMessages.Add($m) }

    if ($nativeTools) {
        $toolsJson = @($toolSpecs | ForEach-Object {
            @{
                type     = "function"
                function = @{
                    name        = $_.name
                    description = $_.desc
                    parameters  = @{
                        type       = "object"
                        properties = @{ $($_.arg) = @{ type = "string" } }
                        required   = @($_.arg)
                    }
                }
            }
        })
    } else {
        $protocol = "To use a tool, reply with ONLY one line of the form`n" +
                    'TOOL {"name": "<tool>", "arguments": {...}}' + "`n" +
                    "and nothing else. The result comes back in a message starting with TOOL RESULT. " +
                    "When you have what you need, reply normally without TOOL. Tools:`n" +
                    (($toolSpecs | ForEach-Object { "- $($_.name) {""$($_.arg)"": ""...""}: $($_.desc)" }) -join "`n")
        $chatMessages[0] = @{ role = "system"; content = $chatMessages[0].content + "`n`n" + $protocol }
    }

    $fullText  = ""
    $maxRounds = 8
    for ($round = 1; $round -le $maxRounds; $round++) {
        $req = @{ model = $effectiveModel; messages = $chatMessages; stream = $false }
        if ($nativeTools) { $req.tools = $toolsJson }
        $json = $req | ConvertTo-Json -Depth 20 -Compress
        try {
            $resp = Invoke-RestMethod "$baseUrl/api/chat" -Method Post -ContentType "application/json" `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 0 -ErrorAction Stop
        } catch {
            Write-Error "Request to $baseUrl/api/chat failed: $(Get-HttpErrorDetail $_)"
            exit 1
        }
        $msg     = $resp.message
        $content = [string]$msg.content

        if ($nativeTools -and $msg.tool_calls) {
            $chatMessages.Add(@{ role = "assistant"; content = $content; tool_calls = $msg.tool_calls })
            foreach ($call in $msg.tool_calls) {
                $result = Invoke-AskTool $call.function.name $call.function.arguments
                $chatMessages.Add(@{ role = "tool"; content = $result; tool_name = $call.function.name })
            }
            continue
        }

        # Small models rarely follow the tool protocol exactly: they emit bare
        # JSON, "open_url {...}", or a call inside a code fence, often wrapped
        # in a refusal. Accept any of those rather than printing them.
        $call = Find-AskToolCall $content
        if ($call) {
            $result = Invoke-AskTool $call.name $call.arguments
            $chatMessages.Add(@{ role = "assistant"; content = $content })
            $chatMessages.Add(@{ role = "user"; content = "TOOL RESULT ($($call.name)):`n$result`n`nNow answer my request: $questionText" })
            continue
        }

        if (-not $nativeTools -and $content -match '(?s)TOOL\s*(\{.*\})') {
            $call = $null
            try { $call = $Matches[1] | ConvertFrom-Json -ErrorAction Stop } catch { }
            if ($call -and $call.name) {
                $result = Invoke-AskTool $call.name $call.arguments
                $chatMessages.Add(@{ role = "assistant"; content = $content })
                $chatMessages.Add(@{ role = "user"; content = "TOOL RESULT ($($call.name)):`n$result`n`nNow answer my request: $questionText" })
                continue
            }
        }

        $fullText = $content.Trim()
        break
    }
    if ($fullText -eq "") { $fullText = "(no answer after $maxRounds tool rounds)" }

    Show-Answer $fullText

    if ($useHistory -and $fullText -notmatch '^\(no answer') {
        Set-AskHistory (@($priorTurns) + @(
            @{ role = "user";      content = $questionText },
            @{ role = "assistant"; content = $fullText }
        ))
    }
    return
}

# ── Send ──────────────────────────────────────────────────────────────────────

try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method      = "POST"
    $req.ContentType = "application/json"
    $req.Timeout     = [System.Threading.Timeout]::Infinite

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $bodyBytes.Length

    $s = $req.GetRequestStream()
    $s.Write($bodyBytes, 0, $bodyBytes.Length)
    $s.Close()
} catch [System.Net.WebException] {
    $ep = if ($Direct) { "Ollama at $url" } else { "cppcoder at $url (is cppcoder --serve running?)" }
    Write-Error "Could not connect to ${ep}`n$($_.Exception.Message)"
    exit 1
}

# ── Stream response ───────────────────────────────────────────────────────────

try {
    $response = $req.GetResponse()
    $reader   = [System.IO.StreamReader]::new($response.GetResponseStream())

    $collected = [System.Text.StringBuilder]::new()

    if ($NoStream -or $Pretty) {
        if ($NoStream) {
            $raw = $reader.ReadToEnd()
            $obj = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            $text = if ($null -ne $obj.PSObject.Properties["message"]) { $obj.message.content } elseif ($null -ne $obj.PSObject.Properties["response"]) { $obj.response } else { $raw }
            [void]$collected.Append($text)
        } else {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $obj) { continue }
                $token = if ($null -ne $obj.PSObject.Properties["message"]) { $obj.message.content } else { $obj.response }
                if ($token) { [void]$collected.Append($token) }
                if ($obj.done -eq $true) { break }
            }
        }
        $fullText = $collected.ToString()
        if ($Pretty -and -not $NoColor) {
            $batCmd = Get-Command bat -ErrorAction SilentlyContinue
            if ($batCmd) {
                $tmp = [System.IO.Path]::GetTempFileName() + ".md"
                [System.IO.File]::WriteAllText($tmp, $fullText)
                bat --language=markdown --style=plain --color=always --paging=never $tmp
                Remove-Item $tmp -ErrorAction SilentlyContinue
            } else {
                Write-Markdown $fullText
            }
        } else {
            Write-Host $fullText
        }
    } else {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $obj) { continue }
            $token = if ($null -ne $obj.PSObject.Properties["message"]) { $obj.message.content } else { $obj.response }
            if ($token) { [void]$collected.Append($token); Write-Host -NoNewline $token }
            if ($obj.done -eq $true) { Write-Host ""; break }
        }
        $fullText = $collected.ToString()
    }

    $reader.Close()
    $response.Close()

    if ($useHistory -and $fullText.Trim() -ne "") {
        $updated = @($priorTurns) + @(
            @{ role = "user";      content = $questionText },
            @{ role = "assistant"; content = $fullText }
        )
        Set-AskHistory $updated
    }
} catch [System.Net.WebException] {
    Write-Error "Request to $url failed: $(Get-HttpErrorDetail $_)"
    exit 1
}
