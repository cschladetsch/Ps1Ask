#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5 tests for ask-fs-tools.ps1 and the ask.ps1 fact-detector changes.
# Run from the repo root:  Invoke-Pester .\tests -Output Detailed

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:AskScript = Join-Path $script:RepoRoot "ask.ps1"
    $script:PwshExe = (Get-Process -Id $PID).Path

    # What ask.ps1 provides to the file tools.
    $script:defaults = @{
        allowed_roots     = @()
        confirm_writes    = $false
        tool_output_chars = 8000
    }
    function Test-AskFlag($value) {
        if ($value -is [bool]) { return $value }
        if ($value -is [string]) { return $value.Trim() -in @("true", "1", "yes", "on") }
        return [bool]$value
    }

    . (Join-Path $script:RepoRoot "ask-fs-tools.ps1")
}

Describe "Resolve-AskPath" {
    BeforeEach {
        $script:root = Join-Path $TestDrive "root"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:defaults["allowed_roots"] = @()
    }

    It "throws on an empty path" {
        { Resolve-AskPath "" } | Should -Throw "*empty*"
        { Resolve-AskPath "   " } | Should -Throw "*empty*"
    }

    It "resolves relative paths against the current folder" {
        Push-Location $script:root
        try {
            $p = Resolve-AskPath "sub\file.txt"
            $p | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:root "sub\file.txt")))
        } finally { Pop-Location }
    }

    It "expands ~ to the home folder" {
        (Resolve-AskPath "~/x.txt") | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $HOME "x.txt")))
    }

    It "strips surrounding quotes" {
        $p = Resolve-AskPath "`"$($script:root)\a.txt`""
        $p | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:root "a.txt")))
    }

    It "allows anything when allowed_roots is empty" {
        { Resolve-AskPath $TestDrive } | Should -Not -Throw
    }

    It "allows the root itself and paths under it" {
        $script:defaults["allowed_roots"] = @($script:root)
        { Resolve-AskPath $script:root } | Should -Not -Throw
        { Resolve-AskPath (Join-Path $script:root "a\b.txt") } | Should -Not -Throw
    }

    It "rejects paths outside the roots" {
        $script:defaults["allowed_roots"] = @($script:root)
        { Resolve-AskPath $TestDrive } | Should -Throw "*outside allowed_roots*"
    }

    It "rejects .. escapes" {
        $script:defaults["allowed_roots"] = @($script:root)
        { Resolve-AskPath (Join-Path $script:root "..\other.txt") } | Should -Throw "*outside allowed_roots*"
    }

    It "rejects a sibling folder that merely shares the root's prefix" {
        $evil = "$($script:root)-evil"
        New-Item -ItemType Directory -Path $evil -Force | Out-Null
        $script:defaults["allowed_roots"] = @($script:root)
        { Resolve-AskPath (Join-Path $evil "x.txt") } | Should -Throw "*outside allowed_roots*"
    }

    It "accepts ~ in allowed_roots" {
        $script:defaults["allowed_roots"] = @("~")
        { Resolve-AskPath "~/anything.txt" } | Should -Not -Throw
    }

    It "rejects a link that points outside the roots" {
        $outside = Join-Path $TestDrive "outside"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $link = Join-Path $script:root "link"
        $kind = if ($IsWindows) { "Junction" } else { "SymbolicLink" }
        try {
            New-Item -ItemType $kind -Path $link -Target $outside -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "cannot create a $kind here: $($_.Exception.Message)"
            return
        }
        $script:defaults["allowed_roots"] = @($script:root)
        { Resolve-AskPath $link } | Should -Throw "*outside allowed_roots*"
        { Resolve-AskPath (Join-Path $link "new.txt") } | Should -Throw "*outside allowed_roots*"
    }
}

Describe "list_dir" {
    BeforeEach {
        $script:root = Join-Path $TestDrive "root"
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $script:root "sub") -Force | Out-Null
        Set-Content (Join-Path $script:root "a.txt") "hello"
        Set-Content (Join-Path $script:root "sub\b.txt") "world"
        $script:defaults["allowed_roots"] = @()
    }

    It "lists files with sizes and folders with a trailing slash" {
        $out = Invoke-AskFsTool list_dir @{ path = $script:root }
        $out | Should -Match "a\.txt\s+\(\d+ bytes\)"
        $out | Should -Match "sub/"
        $out | Should -Not -Match "b\.txt"
    }

    It "descends when recursive is set" {
        $out = Invoke-AskFsTool list_dir @{ path = $script:root; recursive = $true }
        $out | Should -Match "b\.txt"
    }

    It "reports an empty folder" {
        $empty = Join-Path $script:root "empty"
        New-Item -ItemType Directory -Path $empty | Out-Null
        Invoke-AskFsTool list_dir @{ path = $empty } | Should -Match "\(empty\)"
    }

    It "returns an error for a file or a missing folder" {
        Invoke-AskFsTool list_dir @{ path = (Join-Path $script:root "a.txt") } | Should -Match "^error: not a folder"
        Invoke-AskFsTool list_dir @{ path = (Join-Path $script:root "nope") } | Should -Match "^error: not a folder"
    }

    It "is refused outside allowed_roots" {
        $script:defaults["allowed_roots"] = @($script:root)
        Invoke-AskFsTool list_dir @{ path = $TestDrive } | Should -Match "^error: .*outside allowed_roots"
    }
}

Describe "read_file" {
    BeforeEach {
        $script:root = Join-Path $TestDrive "root"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:defaults["allowed_roots"] = @()
        $script:defaults["tool_output_chars"] = 8000
        $script:f = Join-Path $script:root "big.txt"
        [System.IO.File]::WriteAllText($script:f, ("0123456789" * 50))   # 500 chars
    }

    It "returns a whole small file" {
        $small = Join-Path $script:root "small.txt"
        [System.IO.File]::WriteAllText($small, "abc")
        Invoke-AskFsTool read_file @{ path = $small } | Should -Be "abc"
    }

    It "returns a chunk with a continuation hint" {
        $out = Invoke-AskFsTool read_file @{ path = $script:f; offset = 100; length = 50 }
        $out | Should -Match "^0123456789"
        $out | Should -Match "350 characters left, call again with offset=150"
    }

    It "reads the tail without a continuation hint" {
        $out = Invoke-AskFsTool read_file @{ path = $script:f; offset = 490; length = 100 }
        $out | Should -Be "0123456789"
    }

    It "reports an offset past the end" {
        Invoke-AskFsTool read_file @{ path = $script:f; offset = 9999 } | Should -Match "^error: offset 9999 is past the end"
    }

    It "refuses binary files" {
        $bin = Join-Path $script:root "bin.dat"
        [System.IO.File]::WriteAllBytes($bin, [byte[]](65, 0, 66))
        Invoke-AskFsTool read_file @{ path = $bin } | Should -Match "looks binary"
    }

    It "returns an error for a missing file" {
        Invoke-AskFsTool read_file @{ path = (Join-Path $script:root "nope.txt") } | Should -Match "^error: not a file"
    }

    It "does not mistake a missing length for 1 when arguments come from JSON" {
        # Ollama hands tool arguments over as a PSCustomObject, where
        # `$a.length` is the intrinsic 1 rather than `$null`.
        $small = Join-Path $script:root "json-args.txt"
        [System.IO.File]::WriteAllText($small, "abcdef")
        $args = (@{ path = $small } | ConvertTo-Json) | ConvertFrom-Json
        Invoke-AskFsTool read_file $args | Should -Be "abcdef"
    }

    It "caps output at tool_output_chars by default" {
        $script:defaults["tool_output_chars"] = 100
        $out = Invoke-AskFsTool read_file @{ path = $script:f }
        $out | Should -Match "400 characters left, call again with offset=100"
    }
}

Describe "search_files" {
    BeforeEach {
        $script:root = Join-Path $TestDrive "root"
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $script:root "src") -Force | Out-Null
        Set-Content (Join-Path $script:root "src\one.cpp") @("int main() {", "  return confirm_writes;", "}")
        Set-Content (Join-Path $script:root "src\two.md") @("confirm_writes is documented here")
        $script:defaults["allowed_roots"] = @()
        $script:defaults["tool_output_chars"] = 8000
    }

    It "finds matches with file and line number" {
        $out = Invoke-AskFsTool search_files @{ pattern = "confirm_writes"; path = $script:root }
        $out | Should -Match "one\.cpp"
        $out | Should -Match "two\.md"
        $out | Should -Match ":2:"
    }

    It "honours the glob filter" {
        $out = Invoke-AskFsTool search_files @{ pattern = "confirm_writes"; path = $script:root; glob = "*.cpp" }
        $out | Should -Match "one\.cpp"
        $out | Should -Not -Match "two\.md"
    }

    It "reports no matches" {
        Invoke-AskFsTool search_files @{ pattern = "zzz_not_here"; path = $script:root } | Should -Match "\(no matches\)"
    }

    It "returns an error for an empty pattern" {
        Invoke-AskFsTool search_files @{ pattern = ""; path = $script:root } | Should -Match "^error: pattern is empty"
    }

    It "is refused outside allowed_roots" {
        $script:defaults["allowed_roots"] = @($script:root)
        Invoke-AskFsTool search_files @{ pattern = "x"; path = $TestDrive } | Should -Match "^error: .*outside allowed_roots"
    }
}

Describe "write_file" {
    BeforeEach {
        $script:root = Join-Path $TestDrive "root"
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:defaults["allowed_roots"] = @()
        $script:defaults["confirm_writes"] = $false
    }

    It "creates the file and missing parent folders" {
        $f = Join-Path $script:root "a\b\c.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "hi" } | Should -Match "^ok: wrote 2 characters"
        Get-Content $f -Raw | Should -Be "hi"
    }

    It "writes UTF-8 without a BOM" {
        $f = Join-Path $script:root "bom.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "abc" } | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $bytes.Count | Should -Be 3
        $bytes[0] | Should -Be 97
    }

    It "overwrites an existing file" {
        $f = Join-Path $script:root "o.txt"
        Set-Content $f "old old old"
        Invoke-AskFsTool write_file @{ path = $f; content = "new" } | Out-Null
        [System.IO.File]::ReadAllText($f) | Should -Be "new"
    }

    It "does not write, and does not prompt, when there is no console to confirm on" {
        $script:defaults["confirm_writes"] = $true
        Mock Test-AskCanPrompt { $false }
        Mock Read-Host { "y" }
        $f = Join-Path $script:root "no-console.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "x" } | Should -Match "^denied: no interactive console"
        Test-Path $f | Should -BeFalse
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It "does not write when the user answers n" {
        $script:defaults["confirm_writes"] = $true
        Mock Test-AskCanPrompt { $true }
        Mock Read-Host { "n" }
        $f = Join-Path $script:root "denied.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "x" } | Should -Be "denied by user"
        Test-Path $f | Should -BeFalse
    }

    It "does not write on an empty answer" {
        $script:defaults["confirm_writes"] = $true
        Mock Test-AskCanPrompt { $true }
        Mock Read-Host { "" }
        $f = Join-Path $script:root "empty-answer.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "x" } | Should -Be "denied by user"
        Test-Path $f | Should -BeFalse
    }

    It "writes when the user answers y" {
        $script:defaults["confirm_writes"] = $true
        Mock Test-AskCanPrompt { $true }
        Mock Read-Host { "y" }
        $f = Join-Path $script:root "approved.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "x" } | Should -Match "^ok:"
        Test-Path $f | Should -BeTrue
    }

    It "is refused outside allowed_roots and writes nothing" {
        $script:defaults["allowed_roots"] = @($script:root)
        $f = Join-Path $TestDrive "escaped.txt"
        Invoke-AskFsTool write_file @{ path = $f; content = "x" } | Should -Match "^error: .*outside allowed_roots"
        Test-Path $f | Should -BeFalse
    }
}

Describe "Invoke-AskFsTool dispatch and schemas" {
    It "returns `$null for a tool it does not own" {
        Invoke-AskFsTool "run_command" @{ command = "dir" } | Should -BeNullOrEmpty
    }

    It "turns exceptions into error strings instead of throwing" {
        { Invoke-AskFsTool read_file @{ path = "" } } | Should -Not -Throw
        Invoke-AskFsTool read_file @{ path = "" } | Should -Match "^error: "
    }

    It "declares the four file tools with required fields" {
        $schemas = Get-AskFsToolSchemas
        ($schemas | ForEach-Object { $_.function.name } | Sort-Object) -join "," |
            Should -Be "list_dir,read_file,search_files,write_file"
        foreach ($s in $schemas) {
            $s.type | Should -Be "function"
            $s.function.description | Should -Not -BeNullOrEmpty
            $s.function.parameters.required.Count | Should -BeGreaterThan 0
        }
    }

    It "serialises to JSON that Ollama can accept" {
        { Get-AskFsToolSchemas | ConvertTo-Json -Depth 12 } | Should -Not -Throw
    }
}

Describe "ask.ps1 fact detection" {
    BeforeAll {
        # Runs ask.ps1 in a child process (it calls exit) against a scratch
        # config. Port 9 refuses connections, so a question that isn't saved
        # as a fact fails fast instead of reaching a model.
        function Invoke-AskCli([string[]]$AskArgs) {
            $env:ASK_HOME = $script:askHome
            try {
                $out = & $script:PwshExe -NoProfile -File $script:AskScript @AskArgs -OllamaHost 127.0.0.1 -Port 9 2>&1
                return ($out | Out-String)
            } finally { Remove-Item Env:ASK_HOME -ErrorAction SilentlyContinue }
        }
        function Get-SavedFacts {
            $cfg = Join-Path $script:askHome ".ask.json"
            if (-not (Test-Path $cfg)) { return @() }
            return @((Get-Content $cfg -Raw | ConvertFrom-Json).facts)
        }
    }

    BeforeEach {
        $script:askHome = Join-Path $TestDrive "askhome"
        if (Test-Path $script:askHome) { Remove-Item $script:askHome -Recurse -Force }
        New-Item -ItemType Directory -Path $script:askHome -Force | Out-Null
    }

    It "saves a plain first-person statement" {
        Invoke-AskCli @("my", "name", "is", "Christian") | Should -Match "Noted"
        Get-SavedFacts | Should -Contain "my name is Christian"
    }

    It "saves a statement that uses a verb from the list" {
        Invoke-AskCli @("I", "use", "clang") | Should -Match "Noted"
        Get-SavedFacts | Should -Contain "I use clang"
    }

    It "does not save a statement that mentions a Windows path" {
        Invoke-AskCli @("I", "have", "a", "file", "at", "C:\src\foo.txt,", "read", "it") | Should -Not -Match "Noted"
        Get-SavedFacts | Should -BeNullOrEmpty
    }

    It "does not save a statement that mentions a ~ path" {
        Invoke-AskCli @("I", "work", "in", "~/local/repos/Ps1Ask") | Should -Not -Match "Noted"
        Get-SavedFacts | Should -BeNullOrEmpty
    }

    It "does not save a statement that names a relative file" {
        Invoke-AskCli @("I", "have", "src/main.cpp", "open") | Should -Not -Match "Noted"
        Get-SavedFacts | Should -BeNullOrEmpty
    }

    It "does not save statements when -Tools is given" {
        Invoke-AskCli @("-Tools", "I", "use", "clang") | Should -Not -Match "Noted"
        Get-SavedFacts | Should -BeNullOrEmpty
    }

    It "still saves 'remember that ...' without -Tools" {
        Invoke-AskCli @("remember", "that", "the", "build", "box", "is", "cobalt") | Should -Match "Noted"
        Get-SavedFacts | Should -Contain "the build box is cobalt"
    }

    It "does not save questions" {
        Invoke-AskCli @("what", "is", "my", "name") | Should -Not -Match "Noted"
        Get-SavedFacts | Should -BeNullOrEmpty
    }

    It "documents the new tools and config keys in --help" {
        $help = Invoke-AskCli @("--help")
        $help | Should -Match "list_dir"
        $help | Should -Match "search_files"
        $help | Should -Match "write_file"
        $help | Should -Match "allowed_roots"
        $help | Should -Match "confirm_writes"
    }
}
