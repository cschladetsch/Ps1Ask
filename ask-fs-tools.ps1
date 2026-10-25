# ask-fs-tools.ps1 -- filesystem tools for ask: list_dir, search_files, write_file,
# and a hardened read_file. Dot-sourced by ask-tools.ps1.
#
# Uses these from ask.ps1's scope: $defaults, $AskHome.
#   allowed_roots      array of folders the tools may touch; empty = anywhere
#   confirm_writes     y/N before write_file (default true)
#   tool_output_chars  cap on text returned to the model

function Get-AskOutputLimit {
    $n = [int]$defaults["tool_output_chars"]
    if ($n -le 0) { $n = 8000 }
    return $n
}

function Limit-AskText([string]$text) {
    $max = Get-AskOutputLimit
    if ($text.Length -le $max) { return $text }
    return $text.Substring(0, $max) + "`n[truncated: $($text.Length - $max) more characters]"
}

# Expands ~, resolves relative to the current folder, follows links, and
# enforces allowed_roots. Throws on anything outside the roots.
function Resolve-AskPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "path is empty" }
    $p = $Path.Trim().Trim('"').Trim("'")
    if ($p -eq "~" -or $p.StartsWith("~/") -or $p.StartsWith("~\")) {
        $p = Join-Path $HOME $p.Substring(1).TrimStart('/', '\')
    }
    $full = [System.IO.Path]::GetFullPath($(if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p }))

    # Resolve links on the deepest existing ancestor so a junction or symlink
    # can't point outside the roots.
    $probe = $full
    $tail  = @()
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $tail = ,(Split-Path $probe -Leaf) + $tail
        $parent = Split-Path $probe -Parent
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    if ($probe -and (Test-Path -LiteralPath $probe)) {
        $item = Get-Item -LiteralPath $probe -Force
        $real = if ($item.ResolveLinkTarget($true)) { $item.ResolveLinkTarget($true).FullName } else { $item.FullName }
        $full = if ($tail.Count -gt 0) { Join-Path $real ($tail -join [System.IO.Path]::DirectorySeparatorChar) } else { $real }
    }

    $roots = @($defaults["allowed_roots"] | Where-Object { $_ -is [string] -and $_.Trim() -ne "" })
    if ($roots.Count -gt 0) {
        $ok = $false
        foreach ($r in $roots) {
            $rr = [System.IO.Path]::GetFullPath($(if ($r -eq "~" -or $r.StartsWith("~/") -or $r.StartsWith("~\")) { Join-Path $HOME $r.Substring(1).TrimStart('/', '\') } else { $r })).TrimEnd('\', '/')
            if ($full.Equals($rr, [StringComparison]::OrdinalIgnoreCase) -or
                $full.StartsWith($rr + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                $full.StartsWith($rr + [System.IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
        }
        if (-not $ok) { throw "'$full' is outside allowed_roots in ~/.ask.json" }
    }
    return $full
}

function Invoke-AskListDir($a) {
    $dir = Resolve-AskPath ([string]$a.path)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return "error: not a folder: $dir" }
    $recurse = Test-AskFlag $a.recursive
    $items = if ($recurse) { Get-ChildItem -LiteralPath $dir -Force -Recurse -ErrorAction SilentlyContinue | Select-Object -First 500 }
             else          { Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Select-Object -First 500 }
    $lines = foreach ($i in $items) {
        $rel = $i.FullName.Substring($dir.TrimEnd('\', '/').Length).TrimStart('\', '/')
        if ($i.PSIsContainer) { "$rel/" } else { "{0}  ({1:N0} bytes)" -f $rel, $i.Length }
    }
    if (-not $lines) { return "(empty)" }
    return Limit-AskText ((@("$dir") + $lines) -join "`n")
}

function Invoke-AskReadFile($a) {
    $file = Resolve-AskPath ([string]$a.path)
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return "error: not a file: $file" }
    $offset = if ($a.offset) { [int]$a.offset } else { 0 }
    $length = if ($a.length) { [int]$a.length } else { Get-AskOutputLimit }
    $text   = [System.IO.File]::ReadAllText($file)
    if ($text.Contains([char]0)) { return "error: $file looks binary" }
    if ($offset -ge $text.Length -and $text.Length -gt 0) { return "error: offset $offset is past the end ($($text.Length) characters)" }
    $end   = [Math]::Min($text.Length, $offset + $length)
    $chunk = $text.Substring($offset, $end - $offset)
    if ($end -lt $text.Length) { $chunk += "`n[more: $($text.Length - $end) characters left, call again with offset=$end]" }
    return $chunk
}

function Invoke-AskSearchFiles($a) {
    $root = Resolve-AskPath $(if ($a.path) { [string]$a.path } else { "." })
    $pat  = [string]$a.pattern
    if ($pat -eq "") { return "error: pattern is empty" }
    $glob = if ($a.glob) { [string]$a.glob } else { "" }
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        $rgArgs = @("--line-number", "--no-heading", "--max-count", "20", "--max-columns", "200", "--max-columns-preview")
        if ($glob -ne "") { $rgArgs += @("--glob", $glob) }
        $rgArgs += @("--", $pat, $root)
        $out = & rg @rgArgs 2>&1 | Select-Object -First 200
    } else {
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                 Where-Object { $glob -eq "" -or $_.Name -like $glob }
        $out = $files | Select-String -Pattern $pat -ErrorAction SilentlyContinue |
               Select-Object -First 200 | ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" }
    }
    if (-not $out) { return "(no matches)" }
    return Limit-AskText ($out -join "`n")
}

function Invoke-AskWriteFile($a) {
    $file    = Resolve-AskPath ([string]$a.path)
    $content = [string]$a.content
    $exists  = Test-Path -LiteralPath $file
    if (Test-AskFlag $defaults["confirm_writes"]) {
        $verb = if ($exists) { "overwrite" } else { "create" }
        $old  = if ($exists) { " (currently {0:N0} bytes)" -f (Get-Item -LiteralPath $file).Length } else { "" }
        Write-Host "  write_file wants to $verb $file$old with $($content.Length) characters" -ForegroundColor Yellow
        $ans = Read-Host "  Allow? [y/N]"
        if ($ans -notmatch '^\s*y(es)?\s*$') { return "denied by user" }
    }
    $dir = Split-Path $file -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($file, $content, [System.Text.UTF8Encoding]::new($false))
    return "ok: wrote $($content.Length) characters to $file"
}

# Tool definitions in Ollama's native /api/chat "tools" format. Append these to
# whatever list ask-tools.ps1 already sends (replacing its read_file).
function Get-AskFsToolSchemas {
    $str = @{ type = "string" }
    return @(
        @{ type = "function"; function = @{
            name = "list_dir"; description = "List the files and folders in a directory."
            parameters = @{ type = "object"; properties = @{
                path = $str; recursive = @{ type = "boolean"; description = "include subfolders" } }; required = @("path") } } },
        @{ type = "function"; function = @{
            name = "read_file"; description = "Read a text file. Large files come back in chunks; use offset to continue."
            parameters = @{ type = "object"; properties = @{
                path = $str; offset = @{ type = "integer" }; length = @{ type = "integer" } }; required = @("path") } } },
        @{ type = "function"; function = @{
            name = "search_files"; description = "Search file contents for a regex under a folder. Returns path:line:text."
            parameters = @{ type = "object"; properties = @{
                pattern = $str; path = $str; glob = @{ type = "string"; description = "e.g. *.cpp" } }; required = @("pattern") } } },
        @{ type = "function"; function = @{
            name = "write_file"; description = "Create or overwrite a text file. The user is asked to approve."
            parameters = @{ type = "object"; properties = @{ path = $str; content = $str }; required = @("path", "content") } } }
    )
}

# Returns the tool's text result, or $null if $Name isn't a file tool so the
# caller can fall through to its other tools.
function Invoke-AskFsTool([string]$Name, $Arguments) {
    try {
        $r = switch ($Name) {
            "list_dir"     { Invoke-AskListDir $Arguments }
            "read_file"    { Invoke-AskReadFile $Arguments }
            "search_files" { Invoke-AskSearchFiles $Arguments }
            "write_file"   { Invoke-AskWriteFile $Arguments }
            default        { return $null }
        }
        return [string]$r
    } catch {
        return "error: $($_.Exception.Message)"
    }
}