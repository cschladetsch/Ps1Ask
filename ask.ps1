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

.PARAMETER Models
    List models available on the Ollama server, then exit.

.EXAMPLE
    ask what is 1+2
    ask explain CRTP in modern C++
    ask what does PatchApplier do -Model codellama:7b
    ask -SetModel dolphin-8b:latest
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
    [switch] $Models
)

$ErrorActionPreference = "Stop"

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
# Prior turns are sent as context only: an instruction tells the model to
# reply to the final question alone, since small models otherwise tend to
# re-answer every earlier question in the thread.

$historyPath     = Join-Path $HOME ".ask_conversation_state.json"
$maxHistoryTurns = 20   # exchanges, i.e. 40 messages
$useHistory      = ($defaults["history"] -in @($true, "true", 1)) -and -not $NoHistory
$historyNote     = "The earlier messages are conversation history and have already been answered. " +
                   "Use them only as context. Reply only to the final user message; do not repeat, " +
                   "summarise or re-answer earlier questions."

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

# ── Require a question ────────────────────────────────────────────────────────

if (-not $Question) {
    Write-Error "No question provided. Usage: ask what is the rule of five"
    exit 1
}

# ── Resolve effective settings (CLI overrides config) ─────────────────────────

$effectiveModel  = if ($Model      -ne "") { $Model     } else { $defaults["model"]  }
$effectiveHost   = if ($OllamaHost -ne "") { $OllamaHost} else { $defaults["host"]   }
$effectiveSystem = if ($System     -ne "") { $System    } else { $defaults["system"] }

$effectivePort = if ($Port -ne 0) {
    $Port
} elseif ($Direct) {
    $defaults["port_direct"]
} else {
    $defaults["port_serve"]
}

$baseUrl = "http://${effectiveHost}:${effectivePort}"

# ── Detect whether model supports /api/chat or needs /api/generate ────────────

$useChat = $true
try {
    $tagsResp = Invoke-RestMethod "$baseUrl/api/tags" -ErrorAction Stop
    $modelInfo = $tagsResp.models | Where-Object { $_.name -eq $effectiveModel } | Select-Object -First 1
    if ($modelInfo -and $modelInfo.capabilities -notcontains "chat") {
        $useChat = $false
    }
} catch {
    # Can't reach tags endpoint -- assume chat, let it fail naturally
}

$url = if ($useChat) { "$baseUrl/api/chat" } else { "$baseUrl/api/generate" }

# ── Build request ─────────────────────────────────────────────────────────────

$questionText = $Question -join " "

$priorTurns = if ($useHistory) { @(Get-AskHistory) } else { @() }

if ($useChat) {
    $messages = @()
    if ($effectiveSystem -ne "") {
        $messages += @{ role = "system"; content = $effectiveSystem }
    }
    foreach ($turn in $priorTurns) {
        $messages += @{ role = $turn.role; content = $turn.content }
    }
    if ($priorTurns.Count -gt 0) {
        # Placed right before the new question so small models actually heed it.
        $messages += @{ role = "system"; content = $historyNote }
    }
    $messages += @{ role = "user"; content = $questionText }
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
        $promptParts += $historyNote
        $promptParts += "User: $questionText"
        $promptParts += "Assistant:"
    } else {
        $promptParts += $questionText
    }
    $prompt = $promptParts -join "`n"
    $body = @{
        model  = $effectiveModel
        prompt = $prompt
        stream = -not $NoStream.IsPresent
    } | ConvertTo-Json -Depth 5 -Compress
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

    if ($useHistory) {
        $updated = @($priorTurns) + @(
            @{ role = "user";      content = $questionText },
            @{ role = "assistant"; content = $fullText }
        )
        Set-AskHistory $updated
    }
} catch [System.Net.WebException] {
    Write-Error "Stream read failed: $($_.Exception.Message)"
    exit 1
}
