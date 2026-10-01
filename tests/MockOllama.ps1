# MockOllama.ps1 -- a tiny fake Ollama server for the ask tests.
#
# Runs an HttpListener on localhost in a thread job. Each test describes what
# the server should do with Set-MockScenario, runs ask, then inspects the
# requests ask made with Get-MockRequests.
#
#   Start-MockOllama            -> port number
#   Set-MockScenario @{ ... }   -> models, caps, replies (also clears the log)
#   Get-MockRequests            -> [pscustomobject]@{ Method; Path; Body }
#   Stop-MockOllama
#
# Scenario keys (all optional):
#   models  : names returned by GET /api/tags
#   caps    : @{ model = @('completion', 'tools') } for POST /api/show
#             (a model not in caps gets 'completion'; 'missing' gets a 404)
#   replies : one entry per /api/chat call, in order; the last one repeats.
#             A string is the reply text; a hashtable may hold tool_calls.
#   chat404 : models whose /api/chat call returns "model not found"

$script:MockDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ask-mock-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $script:MockDir | Out-Null
$script:MockScenario = Join-Path $script:MockDir "scenario.json"
$script:MockLog      = Join-Path $script:MockDir "requests.jsonl"

function Get-FreeTcpPort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Start-MockOllama {
    $script:MockPort = Get-FreeTcpPort
    $script:MockListener = [System.Net.HttpListener]::new()
    $script:MockListener.Prefixes.Add("http://localhost:$($script:MockPort)/")
    $script:MockListener.Start()
    Set-MockScenario @{}

    $script:MockJob = Start-ThreadJob -ArgumentList $script:MockListener, $script:MockScenario, $script:MockLog -ScriptBlock {
        param($listener, $scenarioPath, $logPath)

        function Send($ctx, [int]$code, [string]$text, [string]$type = "application/json") {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $ctx.Response.StatusCode = $code
            $ctx.Response.ContentType = $type
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.Close()
        }

        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() } catch { break }
            try {
                $req  = $ctx.Request
                $body = ""
                if ($req.HasEntityBody) {
                    $sr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd(); $sr.Close()
                }
                $path = $req.Url.AbsolutePath
                $entry = @{ Method = $req.HttpMethod; Path = $path; Body = $body } | ConvertTo-Json -Compress -Depth 3
                [System.IO.File]::AppendAllText($logPath, $entry + "`n")

                $sc = Get-Content $scenarioPath -Raw | ConvertFrom-Json -AsHashtable
                # @(...) around the whole if: an if-expression unrolls a 1-element array.
                $models = @(if ($sc.models) { $sc.models } else { "dolphin-8b:latest", "qwen2.5:7b" })

                if ($path -eq "/api/tags") {
                    $list = @($models | ForEach-Object { @{ name = $_; size = 4.5GB } })
                    Send $ctx 200 (@{ models = $list } | ConvertTo-Json -Depth 4 -Compress)
                    continue
                }
                if ($path -eq "/page") {
                    $html = if ($sc.page) { $sc.page } else { "<html><body><p>Hello page</p></body></html>" }
                    Send $ctx 200 $html "text/html"
                    continue
                }

                $j = if ($body) { $body | ConvertFrom-Json -AsHashtable } else { @{} }
                if ($path -eq "/api/show") {
                    if ($j.model -eq "missing") { Send $ctx 404 '{"error":"model ''missing'' not found"}'; continue }
                    $caps = @(if ($sc.caps -and $sc.caps.ContainsKey($j.model)) { $sc.caps[$j.model] } else { "completion" })
                    Send $ctx 200 (@{ capabilities = $caps } | ConvertTo-Json -Compress)
                    continue
                }
                if ($path -eq "/api/chat") {
                    if ($sc.chat404 -and (@($sc.chat404) -contains $j.model)) {
                        Send $ctx 404 ('{"error":"model ''' + $j.model + ''' not found"}'); continue
                    }
                    $n = @(Get-Content $logPath | Where-Object { $_ -match '"Path":"/api/chat"' }).Count
                    $replies = @(if ($sc.replies) { $sc.replies } else { "Hello from mock." })
                    $r = $replies[[Math]::Min($n - 1, $replies.Count - 1)]
                    $msg = if ($r -is [string]) { @{ role = "assistant"; content = $r } }
                           else { @{ role = "assistant"; content = [string]$r.content; tool_calls = $r.tool_calls } }

                    if ($j.stream) {
                        $resp = $ctx.Response
                        $resp.StatusCode = 200
                        $resp.ContentType = "application/x-ndjson"
                        $resp.SendChunked = $true
                        $out = $resp.OutputStream
                        $text = [string]$msg.content
                        for ($i = 0; $i -lt $text.Length; $i += 7) {
                            $piece = $text.Substring($i, [Math]::Min(7, $text.Length - $i))
                            $line = (@{ message = @{ role = "assistant"; content = $piece }; done = $false } | ConvertTo-Json -Compress) + "`n"
                            $b = [System.Text.Encoding]::UTF8.GetBytes($line); $out.Write($b, 0, $b.Length); $out.Flush()
                        }
                        $line = (@{ message = @{ role = "assistant"; content = "" }; done = $true } | ConvertTo-Json -Compress) + "`n"
                        $b = [System.Text.Encoding]::UTF8.GetBytes($line); $out.Write($b, 0, $b.Length)
                        $resp.Close()
                    } else {
                        Send $ctx 200 (@{ message = $msg; done = $true } | ConvertTo-Json -Depth 10 -Compress)
                    }
                    continue
                }
                Send $ctx 404 '{"error":"not found"}'
            } catch {
                try { Send $ctx 500 (@{ error = "mock: $($_.Exception.Message)" } | ConvertTo-Json -Compress) } catch { }
            }
        }
    }
    return $script:MockPort
}

function Set-MockScenario([hashtable]$Scenario) {
    $Scenario | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:MockScenario -Encoding utf8
    Set-Content -LiteralPath $script:MockLog -Value $null -NoNewline
}

function Get-MockRequests {
    if (-not (Test-Path $script:MockLog)) { return @() }
    return @(Get-Content $script:MockLog | Where-Object { $_ } | ForEach-Object {
        $e = $_ | ConvertFrom-Json
        [pscustomobject]@{
            Method = $e.Method
            Path   = $e.Path
            Body   = if ($e.Body) { $e.Body | ConvertFrom-Json -AsHashtable } else { $null }
        }
    })
}

function Stop-MockOllama {
    if ($script:MockListener) { try { $script:MockListener.Stop(); $script:MockListener.Close() } catch { } }
    if ($script:MockJob) { $script:MockJob | Wait-Job -Timeout 5 | Out-Null; $script:MockJob | Remove-Job -Force }
    Remove-Item -Recurse -Force $script:MockDir -ErrorAction SilentlyContinue
}
