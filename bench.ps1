<#
.SYNOPSIS
    Benchmarks all installed Ollama models across general and coding questions.

.DESCRIPTION
    Queries each model with a set of questions, measures time-to-first-token
    and total generation time, tokens/sec, and saves results to a JSON file.

.PARAMETER OutputFile
    Path to write JSON results.  Default: ~/bench-<timestamp>.json

.PARAMETER OllamaHost
    Ollama host.  Default: 127.0.0.1

.PARAMETER Port
    Ollama port.  Default: 11434

.PARAMETER Models
    Specific models to test.  Default: all installed models.

.PARAMETER Quick
    Only run one question per category instead of all.

.EXAMPLE
    .\bench.ps1
    .\bench.ps1 -Quick
    .\bench.ps1 -Models qwen2.5-coder:7b,dolphin-8b:latest
    .\bench.ps1 -OutputFile C:\tmp\bench.json
#>
param(
    [string]   $OutputFile  = (Join-Path $HOME "bench-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"),
    [string]   $OllamaHost  = "127.0.0.1",
    [int]      $Port        = 11434,
    [string[]] $Models      = @(),
    [switch]   $Quick
)

$ErrorActionPreference = "Stop"
$baseUrl = "http://${OllamaHost}:${Port}"

# ── Questions ─────────────────────────────────────────────────────────────────

$questions = @(
    @{ category = "general";  prompt = "What is the capital of France? Answer in one sentence." },
    @{ category = "general";  prompt = "Explain the difference between RAM and disk storage in two sentences." },
    @{ category = "general";  prompt = "What are three key differences between TCP and UDP?" },

    @{ category = "coding";   prompt = "Write a merge sort in C++23 using ranges." },
    @{ category = "coding";   prompt = "Explain CRTP in C++ with a short example." },
    @{ category = "coding";   prompt = "What is the C++ rule of five? List each special member function." },
    @{ category = "coding";   prompt = "Write a Rust function that reads a file and returns its lines as a Vec<String>." },
    @{ category = "coding";   prompt = "Show a Python one-liner to flatten a nested list." },
    @{ category = "coding";   prompt = "What is the difference between std::unique_ptr and std::shared_ptr?" }
)

if ($Quick) {
    $questions = @(
        ($questions | Where-Object { $_.category -eq "general" } | Select-Object -First 1),
        ($questions | Where-Object { $_.category -eq "coding"  } | Select-Object -First 1)
    )
}

# ── Discover models ───────────────────────────────────────────────────────────

Write-Host "Querying installed models..." -ForegroundColor Cyan
$tagsResp = Invoke-RestMethod "$baseUrl/api/tags" -ErrorAction Stop
$allModels = $tagsResp.models | ForEach-Object { $_.name }

if ($Models.Count -gt 0) {
    $testModels = $Models
} else {
    $testModels = $allModels
}

Write-Host "Models to test: $($testModels -join ', ')" -ForegroundColor Cyan
Write-Host "Questions per model: $($questions.Count)" -ForegroundColor Cyan
Write-Host ""

# ── Helper: send one request, return timing + response ───────────────────────

function Invoke-ModelQuery {
    param(
        [string] $Model,
        [string] $Prompt,
        [string] $Endpoint  # "chat" or "generate"
    )

    $url = "$baseUrl/api/$Endpoint"

    if ($Endpoint -eq "chat") {
        $bodyObj = @{
            model    = $Model
            messages = @(@{ role = "user"; content = $Prompt })
            stream   = $true
        }
    } else {
        $bodyObj = @{
            model  = $Model
            prompt = $Prompt
            stream = $true
        }
    }

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($bodyObj | ConvertTo-Json -Depth 5 -Compress))

    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method      = "POST"
    $req.ContentType = "application/json"
    $req.Timeout     = 120000   # 2 min per question

    $s = $req.GetRequestStream()
    $s.Write($bodyBytes, 0, $bodyBytes.Length)
    $s.Close()

    $totalStart = [System.Diagnostics.Stopwatch]::StartNew()
    $firstToken = $null
    $collected  = [System.Text.StringBuilder]::new()
    $tokenCount = 0
    $promptTokens = 0
    $evalTokens   = 0

    try {
        $response = $req.GetResponse()
        $reader   = [System.IO.StreamReader]::new($response.GetResponseStream())

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $obj) { continue }

            $token = if ($obj.message) { $obj.message.content } else { $obj.response }

            if ($token) {
                if ($null -eq $firstToken) { $firstToken = $totalStart.Elapsed.TotalMilliseconds }
                [void]$collected.Append($token)
                $tokenCount++
            }

            if ($obj.done -eq $true) {
                # Ollama reports eval_count (output tokens) and prompt_eval_count
                if ($obj.eval_count)        { $evalTokens   = $obj.eval_count }
                if ($obj.prompt_eval_count) { $promptTokens = $obj.prompt_eval_count }
                break
            }
        }

        $reader.Close()
        $response.Close()
    } catch {
        return @{
            error        = $_.Exception.Message
            responseText = ""
            ttft_ms      = -1
            total_ms     = -1
            tokens_sec   = -1
        }
    }

    $totalMs   = $totalStart.Elapsed.TotalMilliseconds
    $tokensPerSec = if ($totalMs -gt 0 -and $evalTokens -gt 0) {
        [math]::Round($evalTokens / ($totalMs / 1000), 1)
    } else { -1 }

    return @{
        error         = ""
        responseText  = $collected.ToString().Trim()
        ttft_ms       = [math]::Round($firstToken ?? -1, 0)
        total_ms      = [math]::Round($totalMs, 0)
        prompt_tokens = $promptTokens
        eval_tokens   = $evalTokens
        tokens_sec    = $tokensPerSec
    }
}

# ── Determine endpoint per model ──────────────────────────────────────────────
# Capabilities come from /api/show (completion, tools, vision, embedding, ...).
# /api/tags doesn't list them and there is no "chat" capability, so the old
# check for "chat" in /api/tags sent every model down /api/generate -- the same
# bug ask.ps1 had. /api/chat works for any completion model; a model without
# "completion" (an embedding model) can't answer at all and is skipped.

function Get-Endpoint([string] $Model) {
    try {
        $body = @{ model = $Model } | ConvertTo-Json -Compress
        $show = Invoke-RestMethod "$baseUrl/api/show" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
    } catch {
        return "chat"   # old Ollama without /api/show, or it failed: let the query report it
    }
    $caps = @($show.capabilities)
    if ($caps.Count -gt 0 -and $caps -notcontains "completion") { return "skip" }
    return "chat"
}

# ── Run benchmark ─────────────────────────────────────────────────────────────

$results = @()
$grandStart = Get-Date

foreach ($model in $testModels) {
    Write-Host "── $model ──────────────────────────────" -ForegroundColor Yellow
    $endpoint = Get-Endpoint $model
    $modelResults = @()

    if ($endpoint -eq "skip") {
        Write-Host "  skipped: can't generate text (embedding model)" -ForegroundColor DarkGray
        Write-Host ""
        continue
    }

    foreach ($q in $questions) {
        Write-Host "  [$($q.category)] $($q.prompt.Substring(0, [Math]::Min(60, $q.prompt.Length)))..." -NoNewline

        $r = Invoke-ModelQuery -Model $model -Prompt $q.prompt -Endpoint $endpoint

        if ($r.error -ne "") {
            Write-Host " ERROR: $($r.error)" -ForegroundColor Red
        } else {
            Write-Host " $($r.tokens_sec) tok/s  TTFT:$($r.ttft_ms)ms  total:$($r.total_ms)ms" -ForegroundColor Green
        }

        $modelResults += [ordered]@{
            category      = $q.category
            prompt        = $q.prompt
            response      = $r.responseText
            ttft_ms       = $r.ttft_ms
            total_ms      = $r.total_ms
            prompt_tokens = $r.prompt_tokens
            eval_tokens   = $r.eval_tokens
            tokens_sec    = $r.tokens_sec
            error         = $r.error
        }
    }

    # Per-model summary
    # @(...): a single result would otherwise be one hashtable, and .Count on
    # a hashtable is its number of keys.
    $successful = @($modelResults | Where-Object { $_.error -eq "" })
    # Values pulled out by key: Measure-Object -Property can't see the keys of
    # these ordered hashtables, so it averaged nothing and every model scored
    # 0 (and the leaderboard, which skips <= 0, was always empty). Questions
    # where Ollama reported no token count (tokens_sec -1) are left out.
    $rates      = @($successful | ForEach-Object { $_.tokens_sec } | Where-Object { $_ -gt 0 })
    $totals     = @($successful | ForEach-Object { $_.total_ms })
    $avgToksec  = if ($rates.Count -gt 0)  { [math]::Round(($rates  | Measure-Object -Average).Average, 1) } else { -1 }
    $avgTotal   = if ($totals.Count -gt 0) { [math]::Round(($totals | Measure-Object -Average).Average, 0) } else { -1 }

    Write-Host "  avg: $avgToksec tok/s  avg total: ${avgTotal}ms  ($($successful.Count)/$($modelResults.Count) ok)" -ForegroundColor Cyan
    Write-Host ""

    $results += [ordered]@{
        model    = $model
        endpoint = $endpoint
        summary  = [ordered]@{
            questions_run    = $modelResults.Count
            questions_ok     = $successful.Count
            avg_tokens_sec   = $avgToksec
            avg_total_ms     = $avgTotal
        }
        questions = $modelResults
    }
}

# ── Write JSON ────────────────────────────────────────────────────────────────

$output = [ordered]@{
    timestamp  = (Get-Date -Format "o")
    host       = $OllamaHost
    port       = $Port
    duration_s = [math]::Round(((Get-Date) - $grandStart).TotalSeconds, 1)
    models     = $results
}

$output | ConvertTo-Json -Depth 10 | Set-Content $OutputFile
Write-Host "Results written to $OutputFile" -ForegroundColor Cyan
Write-Host ""

# ── Print leaderboard ─────────────────────────────────────────────────────────

Write-Host "── Leaderboard (tokens/sec, higher is better) ──────────" -ForegroundColor Cyan
$results |
    Where-Object { $_.summary.avg_tokens_sec -gt 0 } |
    Sort-Object { $_.summary.avg_tokens_sec } -Descending |
    ForEach-Object {
        Write-Host ("  {0,-30} {1,6} tok/s   avg {2,5}ms" -f $_.model, $_.summary.avg_tokens_sec, $_.summary.avg_total_ms)
    }
Write-Host ""