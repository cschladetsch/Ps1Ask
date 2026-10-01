# ask-tools.ps1 -- the tool loop for ask.ps1, dot-sourced only when tools are on.
#
# The model may call fetch_url, open_url, read_file or run_command; results go
# back in and it loops until it produces a plain answer. Only the question and
# the final answer are saved to history, not the tool traffic.
#
# Safety:
#   - run_command asks y/N first ("confirm_commands": false in ~/.ask.json
#     turns that off). With no interactive console it is refused.
#   - Small models rarely follow the tool protocol, so a call written loosely
#     in the reply text (bare JSON, open_url {...}, in a code fence) is
#     accepted -- but only until fetched or file content has entered the
#     conversation. After that, only a native tool call or an exact
#     TOOL {...} reply counts, so text from a web page can't smuggle in a
#     tool call by getting the model to quote it.
#
# Relies on ask.ps1 for: $defaults, $effectiveModel, $questionText,
# Invoke-OllamaJson, Test-AskFlag, Resolve-AskUrl and Open-AskUrl.

$AskToolSpecs = @(
    @{ name = "fetch_url";   arg = "url";     desc = "Download a web page and return its text, to read, check or summarise it." },
    @{ name = "open_url";    arg = "url";     desc = "Open a URL in the user's web browser. Use when asked to open, browse, show or go to a site." },
    @{ name = "read_file";   arg = "path";    desc = "Return the contents of a local text file." },
    @{ name = "run_command"; arg = "command"; desc = "Run a PowerShell command on the user's Windows machine and return its output. The user is asked to approve it first." }
)
$AskToolNames = @($AskToolSpecs | ForEach-Object { $_.name })

# Tools whose results bring outside text into the conversation.
$AskTaintingTools = @("fetch_url", "read_file")

$WebHttp = [System.Net.Http.HttpClient]::new()
$WebHttp.Timeout = [TimeSpan]::FromSeconds(30)
[void]$WebHttp.DefaultRequestHeaders.UserAgent.TryParseAdd(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36")

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

function Confirm-AskCommand([string]$cmd) {
    if (-not (Test-AskFlag $defaults["confirm_commands"])) { return $true }
    if ([Console]::IsInputRedirected) { return $false }
    Write-Host "  model wants to run: " -ForegroundColor Yellow -NoNewline
    Write-Host $cmd
    $answer = Read-Host "  run it? [y/N]"
    return $answer -match '^\s*y'
}

function Invoke-AskTool([string]$name, $toolArgs) {
    try {
        switch ($name) {
            "fetch_url" {
                $u = Resolve-AskUrl ([string]$toolArgs.url)
                Write-Host "  > fetch $u" -ForegroundColor DarkGray
                $resp = $WebHttp.GetAsync($u).GetAwaiter().GetResult()
                try {
                    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if (-not $resp.IsSuccessStatusCode) { return "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                } finally { $resp.Dispose() }
                if ($body -match '(?i)<html|<body|<div') { $body = ConvertFrom-Html $body }
                return Limit-Text $body
            }
            "open_url" {
                $u = Resolve-AskUrl ([string]$toolArgs.url)
                Open-AskUrl $u
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
                if (-not (Confirm-AskCommand $cmd)) {
                    Write-Host "  > not run" -ForegroundColor DarkGray
                    return "The user declined to run this command. Do not try it again; answer without it."
                }
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

# A loosely written tool call anywhere in the reply text, or $null.
function Find-AskToolCall([string]$text) {
    # 1. Any JSON object (one level of nesting) whose "name" is a known tool.
    foreach ($m in [regex]::Matches($text, '\{(?:[^{}]|\{[^{}]*\})*\}')) {
        $o = $null
        try { $o = $m.Value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($o.name -and ($AskToolNames -contains $o.name)) {
            return [pscustomobject]@{ name = $o.name; arguments = $o.arguments }
        }
    }
    # 2. tool_name {args} / tool_name({args})
    $pattern = '\b(' + ($AskToolNames -join '|') + ')\b\s*\(?\s*(\{[^{}]*\})'
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) {
        try {
            $a = $m.Groups[2].Value | ConvertFrom-Json -ErrorAction Stop
            return [pscustomobject]@{ name = $m.Groups[1].Value; arguments = $a }
        } catch { }
    }
    return $null
}

# An exact protocol reply: the whole message is TOOL {...}.
function Find-StrictToolCall([string]$text) {
    if ($text -notmatch '^\s*TOOL\s*(\{[\s\S]*\})\s*$') { return $null }
    $o = $null
    try { $o = $Matches[1] | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($o.name -and ($AskToolNames -contains $o.name)) {
        return [pscustomobject]@{ name = $o.name; arguments = $o.arguments }
    }
    return $null
}

function Invoke-AskToolLoop {
    param(
        [System.Collections.Generic.List[object]] $Messages,
        [switch] $Native
    )

    $chat = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $Messages) { $chat.Add($m) }

    $toolsJson = $null
    if ($Native) {
        $toolsJson = @($AskToolSpecs | ForEach-Object {
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
                    (($AskToolSpecs | ForEach-Object { "- $($_.name) {""$($_.arg)"": ""...""}: $($_.desc)" }) -join "`n")
        if ($chat.Count -gt 0 -and $chat[0].role -eq "system") {
            $chat[0] = @{ role = "system"; content = $chat[0].content + "`n`n" + $protocol }
        } else {
            $chat.Insert(0, @{ role = "system"; content = $protocol })
        }
    }

    $tainted   = $false
    $maxRounds = 8
    for ($round = 1; $round -le $maxRounds; $round++) {
        $req = @{ model = $effectiveModel; messages = $chat; stream = $false }
        if ($Native) { $req.tools = $toolsJson }
        $resp    = Invoke-OllamaJson "/api/chat" $req
        $msg     = $resp.message
        $content = [string]$msg.content

        if ($Native -and $msg.tool_calls) {
            $chat.Add(@{ role = "assistant"; content = $content; tool_calls = $msg.tool_calls })
            foreach ($call in $msg.tool_calls) {
                $name = [string]$call.function.name
                $chat.Add(@{ role = "tool"; content = (Invoke-AskTool $name $call.function.arguments); tool_name = $name })
                if ($AskTaintingTools -contains $name) { $tainted = $true }
            }
            continue
        }

        $call = Find-StrictToolCall $content
        if (-not $call -and -not $tainted) { $call = Find-AskToolCall $content }
        if ($call) {
            $result = Invoke-AskTool $call.name $call.arguments
            if ($AskTaintingTools -contains $call.name) { $tainted = $true }
            $chat.Add(@{ role = "assistant"; content = $content })
            $chat.Add(@{ role = "user"; content = "TOOL RESULT ($($call.name)):`n$result`n`nNow answer my request: $questionText" })
            continue
        }

        return $content.Trim()
    }
    return "(no answer after $maxRounds tool rounds)"
}
