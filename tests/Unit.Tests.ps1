# Unit tests: functions from ask.ps1 and ask-tools.ps1, tested in-process.
#
# ask.ps1 is a script that runs on load, so its functions are lifted out of
# the parsed AST and defined here on their own.

BeforeAll {
    $script:Root      = Split-Path $PSScriptRoot -Parent
    $script:AskScript = Join-Path $Root "ask.ps1"

    $ast   = [System.Management.Automation.Language.Parser]::ParseFile($AskScript, [ref]$null, [ref]$null)
    $funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    # The renderer's colour codes are top-level assignments.
    foreach ($st in $ast.EndBlock.Statements) {
        if ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $st.Left.Extent.Text -match '^\$(ESC|Ansi\w+)$') {
            . ([scriptblock]::Create($st.Extent.Text))
        }
    }
    foreach ($name in 'Format-MdInline', 'New-MdRenderer', 'Write-MdLine', 'Add-MdText', 'Complete-Md',
                      'Write-Markdown', 'Get-AskStatement', 'Get-AskFactKey', 'Resolve-AskUrl',
                      'Open-AskUrl', 'Test-AskFlag') {
        $f = $funcs | Where-Object Name -eq $name | Select-Object -First 1
        if (-not $f) { throw "function $name not found in ask.ps1" }
        . ([scriptblock]::Create($f.Extent.Text))
    }

    # Rendered lines, colour codes removed.
    function Get-Rendered([string]$text) {
        $lines = & { Write-Markdown $text } 6>&1 | ForEach-Object { [string]$_ }
        return @($lines | ForEach-Object { $_ -replace "\x1b\[[0-9;]*m", "" } | Where-Object { $_ -ne "" })
    }
    function Strip([string]$s) { return $s -replace "\x1b\[[0-9;]*m", "" }

    # ask-tools.ps1 expects these from ask.ps1.
    $script:defaults = @{ tool_output_chars = 40; confirm_commands = $false }
    $script:effectiveModel = "test-model"
    $script:questionText   = "test question"
    $env:ASK_NO_LAUNCH = "1"
    . (Join-Path $Root "ask-tools.ps1")
}

AfterAll {
    Remove-Item Env:ASK_NO_LAUNCH -ErrorAction SilentlyContinue
}

Describe "Format-MdInline" {
    It "renders a code span in green without the backticks" {
        Format-MdInline 'use `std::move` here' | Should -Be "use $($AnsiGreen)std::move$AnsiReset here"
    }
    It "renders **bold**" {
        Format-MdInline 'a **big** deal' | Should -Be "a $($AnsiBold)big$AnsiReset deal"
    }
    It "renders *italics* dim" {
        Format-MdInline 'an *aside*' | Should -Be "an $($AnsiDim)aside$AnsiReset"
    }
    It "leaves ** inside a code span alone" {
        Strip (Format-MdInline '`a**b**`') | Should -Be 'a**b**'
    }
}

Describe "Markdown renderer" {
    It "drops ### from a third-level heading" {
        Get-Rendered "### Rule of Five" | Should -Be @("Rule of Five")
    }
    It "renders * bullets as •, not italics" {
        Get-Rendered "* one *two*" | Should -Be @("  • one two")
    }
    It "keeps numbered list numbers" {
        Get-Rendered "1. first`n2. second" | Should -Be @("  1. first", "  2. second")
    }
    It "hides code fences, shows the language and the code" {
        Get-Rendered "``````cpp`nint x;`n``````" | Should -Be @("cpp", "int x;")
    }
    It "doesn't format markdown inside a code block" {
        Get-Rendered "```````n# not a heading`n- not a bullet`n``````" | Should -Be @("# not a heading", "- not a bullet")
    }
    It "renders --- as a rule" {
        Get-Rendered "---" | Should -Match '^─{60}$'
    }
    It "gives the same output streamed one character at a time" {
        $text = "### H`n`n- **a** and ``b```n1. one`n``````cpp`nx;`n```````nend"
        $whole = Get-Rendered $text
        $r = New-MdRenderer
        $streamed = & { foreach ($c in $text.ToCharArray()) { Add-MdText $r ([string]$c) }; Complete-Md $r } 6>&1 |
            ForEach-Object { ([string]$_) -replace "\x1b\[[0-9;]*m", "" } | Where-Object { $_ -ne "" }
        @($streamed) | Should -Be $whole
    }
    It "handles CRLF line endings" {
        Get-Rendered "# A`r`n- b`r`n" | Should -Be @("A", "  • b")
    }
}

Describe "Get-AskStatement: statements are facts" {
    It "'<Text>' is saved as '<Fact>'" -TestCases @(
        @{ Text = "my name is Christian";                  Fact = "my name is Christian" }
        @{ Text = "I live in East Melbourne";              Fact = "I live in East Melbourne" }
        @{ Text = "I work at Oracle";                      Fact = "I work at Oracle" }
        @{ Text = "our build server is cobalt";            Fact = "our build server is cobalt" }
        @{ Text = "remember that the build box is cobalt"; Fact = "the build box is cobalt" }
        @{ Text = "remember: my cat is Raffy";             Fact = "my cat is Raffy" }
    ) {
        Get-AskStatement $Text | Should -Be $Fact
    }
}

Describe "Get-AskStatement: questions are not facts" {
    It "'<Text>' goes to the model" -TestCases @(
        @{ Text = "what is my name" }
        @{ Text = "my name is Christian?" }
        @{ Text = "explain CRTP" }
        @{ Text = "I have a question about templates" }
        @{ Text = "my build is failing" }
        @{ Text = "rust is faster than c++" }
        @{ Text = "I am getting an error in CMake" }
        @{ Text = "tell me a joke" }
    ) {
        Get-AskStatement $Text | Should -BeNullOrEmpty
    }
}

Describe "Get-AskFactKey" {
    It "'<Fact>' has key '<Key>'" -TestCases @(
        @{ Fact = "my name is Christian";          Key = "my name" }
        @{ Fact = "I live in East Melbourne";      Key = "i live" }
    ) {
        Get-AskFactKey $Fact | Should -Be $Key
    }
    It "gives no key to a fact that should accumulate" {
        Get-AskFactKey "I use vim" | Should -BeNullOrEmpty
    }
}

Describe "Resolve-AskUrl" {
    It "'<In>' becomes '<Out>'" -TestCases @(
        @{ In = "old.reddit.com";          Out = "https://old.reddit.com" }
        @{ In = "http://localhost:8080/x"; Out = "http://localhost:8080/x" }
    ) {
        Resolve-AskUrl $In | Should -Be $Out
    }
}

Describe "Test-AskFlag" {
    It "<Value> is <Expected>" -TestCases @(
        @{ Value = $true;   Expected = $true }
        @{ Value = "true";  Expected = $true }
        @{ Value = 1;       Expected = $true }
        @{ Value = "no";    Expected = $false }
        @{ Value = "false"; Expected = $false }
    ) {
        Test-AskFlag $Value | Should -Be $Expected
    }
}

Describe "Find-AskToolCall (loose)" {
    It "finds bare JSON" {
        $c = Find-AskToolCall '{"name": "open_url", "arguments": {"url": "x.com"}}'
        $c.name | Should -Be "open_url"
        $c.arguments.url | Should -Be "x.com"
    }
    It "finds a call inside a code fence" {
        (Find-AskToolCall "``````json`n{""name"": ""read_file"", ""arguments"": {""path"": ""a.txt""}}`n``````").name | Should -Be "read_file"
    }
    It "finds tool_name {args}" {
        (Find-AskToolCall 'open_url {"url": "https://old.reddit.com"}').arguments.url | Should -Be "https://old.reddit.com"
    }
    It "finds a call wrapped in a refusal" {
        $text = "I'm sorry, I can't browse.`n``````sh`nopen_url {""url"": ""https://old.reddit.com""}`n``````"
        (Find-AskToolCall $text).name | Should -Be "open_url"
    }
    It "ignores JSON naming an unknown tool" {
        Find-AskToolCall '{"name": "rm_rf", "arguments": {}}' | Should -BeNullOrEmpty
    }
    It "ignores JSON without a name" {
        Find-AskToolCall 'config: {"a": 1, "b": 2}' | Should -BeNullOrEmpty
    }
}

Describe "Find-StrictToolCall" {
    It "accepts a reply that is exactly TOOL {...}" {
        (Find-StrictToolCall 'TOOL {"name": "fetch_url", "arguments": {"url": "a.com"}}').name | Should -Be "fetch_url"
    }
    It "rejects TOOL {...} in the middle of other text" {
        Find-StrictToolCall 'The page says TOOL {"name": "run_command", "arguments": {"command": "x"}}' | Should -BeNullOrEmpty
    }
    It "rejects an unknown tool" {
        Find-StrictToolCall 'TOOL {"name": "format_disk", "arguments": {}}' | Should -BeNullOrEmpty
    }
    It "rejects invalid JSON" {
        Find-StrictToolCall 'TOOL {name: run_command}' | Should -BeNullOrEmpty
    }
}

Describe "ConvertFrom-Html and Limit-Text" {
    It "drops scripts and styles" {
        ConvertFrom-Html "<html><head><style>p{}</style></head><body><script>evil()</script><p>Hi</p></body></html>" | Should -Be "Hi"
    }
    It "decodes entities" {
        ConvertFrom-Html "<p>a &amp; b &lt;c&gt;</p>" | Should -Be "a & b <c>"
    }
    It "truncates long text at tool_output_chars" {
        $t = Limit-Text ("x" * 100)
        $t | Should -Be (("x" * 40) + "`n... [truncated]")
    }
}

Describe "Invoke-AskTool" {
    It "reports an unknown tool" {
        Invoke-AskTool "nope" @{} | Should -Be "Unknown tool 'nope'."
    }
    It "reads a file" {
        $f = Join-Path $TestDrive "a.txt"; Set-Content $f "file body" -NoNewline
        Invoke-AskTool "read_file" @{ path = $f } 6>$null | Should -Be "file body"
    }
    It "returns an error for a missing file" {
        Invoke-AskTool "read_file" @{ path = (Join-Path $TestDrive "nope.txt") } 6>$null | Should -BeLike "Error:*"
    }
    It "runs a command when confirmation is off" {
        $r = Invoke-AskTool "run_command" @{ command = "Write-Output tool-ran" } 6>$null
        $r | Should -Match "exit code: 0"
        $r | Should -Match "tool-ran"
    }
    It "doesn't run a command the user declines" {
        Mock Confirm-AskCommand { $false }
        Invoke-AskTool "run_command" @{ command = "Write-Output should-not-run" } 6>$null | Should -BeLike "The user declined*"
    }
    It "opens a URL (ASK_NO_LAUNCH: printed, not launched)" {
        Invoke-AskTool "open_url" @{ url = "example.com" } 6>$null | Should -Be "Opened https://example.com in the user's default browser."
    }
}
