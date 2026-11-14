#requires -Version 5.1

<#
.SYNOPSIS
Imports a converted KiCad symbol, footprint, and 3D model package into a
project-local library.

.DESCRIPTION
The source directory must contain exactly one *.kicad_sym file, exactly one
*.pretty directory, and zero or one *.3dmodels directory. All top-level
symbols and all footprints are imported. Existing names are never replaced.
An existing 3D model is reused only when its SHA-256 hash matches the source.

The target project must already contain <LibraryName>.kicad_sym and
<LibraryName>.pretty. The script upgrades source assets with KiCad CLI,
validates a staged merged library, creates a backup, and then commits the
new assets. Source 3D model references must use
../<source-name>.3dmodels/<file>; supported source files are STEP, STP, and
WRL files stored directly in the model directory.

ProjectRoot is the target asset directory. SymbolTableRoot and
FootprintTableRoot optionally select existing sym-lib-table and fp-lib-table
directories independently. Explicitly selected tables are backed up and their
target nickname is mapped to the absolute asset URI during Apply.

.EXAMPLE
.\tools\Import-KiCadLibraryAssets.ps1 `
    -SourceRoot '.\incoming\NSI8141W1' `
    -ProjectRoot '.' `
    -LibraryName '6221'

.EXAMPLE
.\tools\Import-KiCadLibraryAssets.ps1 `
    -SourceRoot '.\incoming\NSI8141W1' `
    -ProjectRoot '.' `
    -LibraryName '6221' `
    -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LibraryName,

    [string]$SymbolTableRoot,

    [string]$FootprintTableRoot,

    [switch]$ReuseExistingFootprints,

    [string]$KiCadCliPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8 = [System.Text.Encoding]::UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$stageRootPath = $null
$targetTempPath = $null
$tableTemporaryPaths = New-Object 'System.Collections.Generic.List[string]'
$tableLocks = New-Object 'System.Collections.Generic.List[System.Threading.Mutex]'

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $item = Get-Item -LiteralPath $LiteralPath
    if (-not $item.PSIsContainer) {
        throw "$Label is not a directory: $LiteralPath"
    }

    return [System.IO.Path]::GetFullPath($item.FullName)
}

function Get-SingleChild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $true)]
        [ValidateSet('File', 'Directory')]
        [string]$Kind
    )

    if ($Kind -eq 'File') {
        $items = @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter)
    }
    else {
        $items = @(Get-ChildItem -LiteralPath $Directory -Directory -Filter $Filter)
    }

    if ($items.Count -ne 1) {
        throw "Expected exactly one $Kind matching '$Filter' in '$Directory'; found $($items.Count)."
    }

    return $items[0]
}

function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        $Value = ''
    }
    if ($Value.Length -gt 0 -and
        -not [System.Text.RegularExpressions.Regex]::IsMatch($Value, '[\s\"]')) {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashCount = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }

        if ($character -eq [char]34) {
            for ($repeat = 0; $repeat -lt (2 * $backslashCount + 1); $repeat++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
            $backslashCount = 0
            continue
        }

        for ($repeat = 0; $repeat -lt $backslashCount; $repeat++) {
            [void]$builder.Append([char]92)
        }
        [void]$builder.Append($character)
        $backslashCount = 0
    }

    for ($repeat = 0; $repeat -lt (2 * $backslashCount); $repeat++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-KiCadCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quotedArguments = @(
        $Arguments | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument -Value ([string]$_)
        }
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:KiCadCliPath
    $startInfo.Arguments = [System.String]::Join(' ', $quotedArguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:utf8
    $startInfo.StandardErrorEncoding = $script:utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutText = ''
    $stderrText = ''
    try {
        if (-not $process.Start()) {
            throw "Could not start KiCad CLI: $script:KiCadCliPath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    if ($exitCode -ne 0) {
        $details = New-Object 'System.Collections.Generic.List[string]'
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            [void]$details.Add($stdoutText.TrimEnd())
        }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            [void]$details.Add($stderrText.TrimEnd())
        }
        $message = [System.String]::Join([Environment]::NewLine, $details.ToArray())
        throw "KiCad CLI failed with exit code $exitCode.`n$message"
    }

    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        Write-Verbose ('KiCad stdout:' + [Environment]::NewLine + $stdoutText.TrimEnd())
    }
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        Write-Verbose ('KiCad stderr:' + [Environment]::NewLine + $stderrText.TrimEnd())
    }
}

function Get-CanonicalSymbolBlocks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SymbolLibraryPath
    )

    $lines = [System.IO.File]::ReadAllLines($SymbolLibraryPath, $script:utf8)
    $blocks = New-Object 'System.Collections.Generic.List[object]'

    for ($index = 0; $index -lt $lines.Length; $index++) {
        $match = [System.Text.RegularExpressions.Regex]::Match(
            $lines[$index],
            '^\t\(symbol "(.+)"$'
        )
        if (-not $match.Success) {
            continue
        }

        $endIndex = -1
        for ($scanIndex = $index + 1; $scanIndex -lt $lines.Length; $scanIndex++) {
            if ($lines[$scanIndex] -eq "`t)") {
                $endIndex = $scanIndex
                break
            }
        }

        if ($endIndex -lt 0) {
            throw "Could not find the end of symbol '$($match.Groups[1].Value)'."
        }

        $blocks.Add([PSCustomObject]@{
            Name = $match.Groups[1].Value
            Lines = [string[]]$lines[$index..$endIndex]
        })
        $index = $endIndex
    }

    return $blocks.ToArray()
}

function Test-LibraryTableEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TablePath,

        [Parameter(Mandatory = $true)]
        [string]$Nickname
    )

    if (-not [System.IO.File]::Exists($TablePath)) {
        Write-Warning "Library table not found: $TablePath"
        return
    }

    $tableText = [System.IO.File]::ReadAllText($TablePath, $script:utf8)
    $needle = '(name "' + $Nickname + '")'
    if ($tableText.IndexOf($needle, [System.StringComparison]::Ordinal) -lt 0) {
        Write-Warning "Library nickname '$Nickname' was not found in '$TablePath'."
    }
}

function Enter-LibraryTableLocks {
    param([string[]]$TablePaths)
    foreach ($tablePath in @($TablePaths | Sort-Object -Unique)) {
        $pathBytes = [System.Text.Encoding]::UTF8.GetBytes($tablePath.ToUpperInvariant())
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { $key = [BitConverter]::ToString($sha256.ComputeHash($pathBytes)).Replace('-', '') }
        finally { $sha256.Dispose() }
        $tableMutex = New-Object System.Threading.Mutex -ArgumentList $false, ('Local\KiCadLibraryImporter-Table-' + $key)
        $acquired = $false
        try {
            try { $acquired = $tableMutex.WaitOne(0, $false) }
            catch [System.Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { throw "Another import is using this library table: $tablePath" }
            $script:tableLocks.Add($tableMutex)
        }
        finally { if (-not $acquired) { $tableMutex.Dispose() } }
    }
}

function Get-TableListNodes {
    param([string]$Text)

    $stack = New-Object 'System.Collections.Generic.List[int]'
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    $inString = $false
    $escaped = $false
    for ($position = 0; $position -lt $Text.Length; $position++) {
        $character = $Text[$position]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($character -eq [char]92) { $escaped = $true }
            elseif ($character -eq [char]34) { $inString = $false }
            continue
        }
        if ($character -eq [char]34) {
            if ($stack.Count -eq 0) { throw 'Unexpected string outside library table.' }
            $inString = $true
        }
        elseif ($character -eq '(') { $stack.Add($position) }
        elseif ($character -eq ')') {
            if ($stack.Count -eq 0) { throw 'Unbalanced library table parentheses.' }
            $start = $stack[$stack.Count - 1]
            $stack.RemoveAt($stack.Count - 1)
            $nodeText = $Text.Substring($start, $position - $start + 1)
            $head = [regex]::Match($nodeText, '^\(\s*([^\s()"]+)')
            if (-not $head.Success) { throw 'Invalid library table expression.' }
            $nodes.Add([PSCustomObject]@{
                Start = $start; Length = $nodeText.Length; Depth = $stack.Count
                Head = $head.Groups[1].Value; Text = $nodeText
            })
        }
        elseif ($stack.Count -eq 0 -and -not [char]::IsWhiteSpace($character)) {
            throw 'Unexpected content outside library table.'
        }
    }
    if ($inString -or $stack.Count -ne 0) { throw 'Unterminated library table expression.' }
    return $nodes.ToArray()
}

function New-LibraryTableUpdate {
    param([string]$Root, [string]$FileName, [string]$TableKind, [string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        Test-LibraryTableEntry -TablePath ([System.IO.Path]::Combine($script:projectDirectory, $FileName)) -Nickname $script:LibraryName
        return
    }
    $directory = Resolve-ExistingDirectory -LiteralPath $Root -Label $FileName
    $tablePath = [System.IO.Path]::Combine($directory, $FileName)
    if (-not [System.IO.File]::Exists($tablePath)) { throw "Library table not found: $tablePath" }
    $originalText = [System.IO.File]::ReadAllText($tablePath, $script:utf8)
    $nodes = @(Get-TableListNodes -Text $originalText)
    $roots = @($nodes | Where-Object { $_.Depth -eq 0 })
    if ($roots.Count -ne 1 -or $roots[0].Head -cne $TableKind) {
        throw "Expected one $TableKind expression in '$tablePath'."
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($node in @($nodes | Where-Object { $_.Depth -eq 1 -and $_.Head -eq 'lib' })) {
        $children = @($nodes | Where-Object { $_.Depth -eq 2 -and $_.Start -gt $node.Start -and $_.Start -lt ($node.Start + $node.Length) })
        $names = @($children | Where-Object { $_.Head -eq 'name' })
        if ($names.Count -ne 1) { throw "Invalid library nickname in '$tablePath'." }
        $nameValue = [regex]::Match($names[0].Text, '^\(name\s+(?:"((?:\\.|[^"\\])*)"|([^\s()]+))\s*\)$')
        if (-not $nameValue.Success) { throw "Invalid library nickname in '$tablePath'." }
        $name = if ($nameValue.Groups[1].Success) { $nameValue.Groups[1].Value.Replace('\"', '"').Replace('\\', '\') } else { $nameValue.Groups[2].Value }
        if ($name -ceq $script:LibraryName) { $entries.Add($node) }
    }
    if ($entries.Count -gt 1) { throw "Duplicate library nickname '$script:LibraryName' in '$tablePath'." }
    $uri = $TargetPath.Replace([char]92, [char]47).Replace('"', '\"')
    $uriField = '(uri "' + $uri + '")'
    $newText = $originalText
    if ($entries.Count -eq 0) {
        $entry = '  (lib (name "' + $script:LibraryName + '")(type "KiCad")' + $uriField + '(options "")(descr ""))'
        $newText = $originalText.Insert($roots[0].Start + $roots[0].Length - 1, "`n" + $entry + "`n")
    }
    else {
        $entry = $entries[0]
        $entryText = $entry.Text
        foreach ($field in @('uri', 'type')) {
            $fields = @($nodes | Where-Object { $_.Depth -eq 2 -and $_.Head -eq $field -and $_.Start -gt $entry.Start -and $_.Start -lt ($entry.Start + $entry.Length) })
            if ($fields.Count -gt 1) { throw "Duplicate $field field in '$tablePath'." }
            $replacement = if ($field -eq 'uri') { $uriField } else { '(type "KiCad")' }
            if ($fields.Count -eq 0) { $entryText = $entryText.Insert($entryText.Length - 1, $replacement) }
            else {
                # Locate fields afresh after each replacement so offsets remain valid.
                $currentFields = @(Get-TableListNodes -Text $entryText | Where-Object { $_.Depth -eq 1 -and $_.Head -eq $field })
                $entryText = $entryText.Remove($currentFields[0].Start, $currentFields[0].Length).Insert($currentFields[0].Start, $replacement)
            }
        }
        $newText = $originalText.Remove($entry.Start, $entry.Length).Insert($entry.Start, $entryText)
    }
    if ($newText -cne $originalText) {
        Write-Warning "Library table will be updated: $tablePath -> $TargetPath"
        return [PSCustomObject]@{ Path = $tablePath; FileName = $FileName; Text = $newText; OriginalText = $originalText }
    }
}

function Write-LibraryTableFile {
    param([string]$TablePath, [string]$Text, [string]$RestoreFrom)

    $temporaryPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($TablePath), '.library-table-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $temporaryBackupPath = $temporaryPath + '.bak'
    $script:tableTemporaryPaths.Add($temporaryPath)
    $script:tableTemporaryPaths.Add($temporaryBackupPath)
    if ([string]::IsNullOrEmpty($RestoreFrom)) { [System.IO.File]::WriteAllText($temporaryPath, $Text, $script:utf8NoBom) }
    else { [System.IO.File]::Copy($RestoreFrom, $temporaryPath, $false) }
    [System.IO.File]::Replace($temporaryPath, $TablePath, $temporaryBackupPath, $true)
}

try {
    $sourceDirectory = Resolve-ExistingDirectory -LiteralPath $SourceRoot -Label 'SourceRoot'
    $projectDirectory = Resolve-ExistingDirectory -LiteralPath $ProjectRoot -Label 'ProjectRoot'

    . ([System.IO.Path]::Combine($PSScriptRoot, 'KiCadEnvironment.ps1'))
    $script:KiCadCliPath = Resolve-KiCadCliPath -Path $KiCadCliPath

    if ($LibraryName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $LibraryName.IndexOf(':') -ge 0 -or
        $LibraryName.IndexOf('"') -ge 0) {
        throw "LibraryName contains characters that cannot be used safely: $LibraryName"
    }

    $sourceSymbolLibrary = Get-SingleChild -Directory $sourceDirectory -Filter '*.kicad_sym' -Kind File
    $sourceFootprintLibrary = Get-SingleChild -Directory $sourceDirectory -Filter '*.pretty' -Kind Directory
    $sourceModelLibraries = @(Get-ChildItem -LiteralPath $sourceDirectory -Directory -Filter '*.3dmodels')
    if ($sourceModelLibraries.Count -gt 1) {
        throw "Expected zero or one *.3dmodels directory; found $($sourceModelLibraries.Count)."
    }
    $sourceModelLibrary = if ($sourceModelLibraries.Count -eq 1) { $sourceModelLibraries[0] } else { $null }

    $targetSymbolLibrary = [System.IO.Path]::Combine($projectDirectory, "$LibraryName.kicad_sym")
    $targetFootprintLibrary = [System.IO.Path]::Combine($projectDirectory, "$LibraryName.pretty")
    $targetModelLibrary = [System.IO.Path]::Combine($projectDirectory, "$LibraryName.3dmodels")

    if (-not [System.IO.File]::Exists($targetSymbolLibrary)) {
        throw "Target symbol library was not found: $targetSymbolLibrary"
    }
    if (-not [System.IO.Directory]::Exists($targetFootprintLibrary)) {
        throw "Target footprint library was not found: $targetFootprintLibrary"
    }

    $tablePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($SymbolTableRoot)) {
        $SymbolTableRoot = Resolve-ExistingDirectory -LiteralPath $SymbolTableRoot -Label 'SymbolTableRoot'
        $tablePaths += [System.IO.Path]::Combine($SymbolTableRoot, 'sym-lib-table')
    }
    if (-not [string]::IsNullOrWhiteSpace($FootprintTableRoot)) {
        $FootprintTableRoot = Resolve-ExistingDirectory -LiteralPath $FootprintTableRoot -Label 'FootprintTableRoot'
        $tablePaths += [System.IO.Path]::Combine($FootprintTableRoot, 'fp-lib-table')
    }
    Enter-LibraryTableLocks -TablePaths $tablePaths
    $tableUpdates = @(
        New-LibraryTableUpdate -Root $SymbolTableRoot -FileName 'sym-lib-table' -TableKind 'sym_lib_table' -TargetPath $targetSymbolLibrary
        New-LibraryTableUpdate -Root $FootprintTableRoot -FileName 'fp-lib-table' -TableKind 'fp_lib_table' -TargetPath $targetFootprintLibrary
    )
    $targetModelPrefix = '${KIPRJMOD}/' + $LibraryName + '.3dmodels/'
    foreach ($tableRoot in @($SymbolTableRoot, $FootprintTableRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($tableRoot) -and
            -not [string]::Equals((Resolve-ExistingDirectory -LiteralPath $tableRoot -Label 'Library table'), $projectDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            $targetModelPrefix = $targetModelLibrary.Replace([char]92, [char]47) + '/'
        }
    }

    $stageParent = [System.IO.Path]::Combine($projectDirectory, 'tmp')
    [void][System.IO.Directory]::CreateDirectory($stageParent)
    $stageParentItem = Get-Item -LiteralPath $stageParent
    if (($stageParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use a reparse point as the staging directory: $stageParent"
    }
    $stageRootPath = [System.IO.Path]::Combine($stageParent, '.kicad-library-import-' + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($stageRootPath)

    $upgradedSymbolLibrary = [System.IO.Path]::Combine($stageRootPath, 'source.kicad_sym')
    Invoke-KiCadCli -Arguments @(
        'sym', 'upgrade', $sourceSymbolLibrary.FullName,
        '--output', $upgradedSymbolLibrary,
        '--force'
    )

    $upgradedFootprintLibrary = [System.IO.Path]::Combine($stageRootPath, 'source.pretty')
    Invoke-KiCadCli -Arguments @(
        'fp', 'upgrade', $sourceFootprintLibrary.FullName,
        '--output', $upgradedFootprintLibrary,
        '--force'
    )

    $sourceSymbolBlocks = @(Get-CanonicalSymbolBlocks -SymbolLibraryPath $upgradedSymbolLibrary)
    if ($sourceSymbolBlocks.Count -eq 0) {
        throw 'The upgraded source library contains no top-level symbols.'
    }

    $targetSymbolText = [System.IO.File]::ReadAllText($targetSymbolLibrary, $utf8)
    $targetSymbolLines = [System.IO.File]::ReadAllLines($targetSymbolLibrary, $utf8)
    foreach ($block in $sourceSymbolBlocks) {
        $marker = "`t(symbol `"$($block.Name)`""
        if (@($targetSymbolLines | Where-Object { $_ -eq $marker }).Count -ne 0) {
            throw "Target symbol already exists: $($block.Name)"
        }
    }

    $upgradedFootprints = @(Get-ChildItem -LiteralPath $upgradedFootprintLibrary -File -Filter '*.kicad_mod')
    if ($upgradedFootprints.Count -eq 0) {
        throw 'The upgraded source footprint library contains no footprints.'
    }

    $footprintNames = @{}
    $reusedFootprintNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($footprint in $upgradedFootprints) {
        $footprintNames[$footprint.BaseName] = $true
        $targetPath = [System.IO.Path]::Combine($targetFootprintLibrary, $footprint.Name)
        if ([System.IO.File]::Exists($targetPath)) {
            if (-not $ReuseExistingFootprints) {
                throw "Target footprint already exists: $($footprint.BaseName)"
            }
            [void]$reusedFootprintNames.Add($footprint.BaseName)
        }
    }

    $sourceModelFiles = @()
    $modelFilesToCopy = New-Object 'System.Collections.Generic.List[object]'
    $reusedModelFiles = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $sourceModelLibrary) {
        $sourceModelFiles = @(
            Get-ChildItem -LiteralPath $sourceModelLibrary.FullName -File |
                Where-Object { $_.Extension -in @('.step', '.stp', '.wrl') }
        )
        foreach ($modelFile in $sourceModelFiles) {
            $targetPath = [System.IO.Path]::Combine($targetModelLibrary, $modelFile.Name)
            if ([System.IO.File]::Exists($targetPath)) {
                $sourceHash = (Get-FileHash -LiteralPath $modelFile.FullName -Algorithm SHA256).Hash
                $targetHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                if ($sourceHash -ne $targetHash) {
                    throw "Target 3D model exists with different content: $($modelFile.Name)"
                }
                [void]$reusedModelFiles.Add($modelFile.Name)
            }
            else {
                [void]$modelFilesToCopy.Add($modelFile)
            }
        }
    }

    $sourceFootprintNickname = [System.IO.Path]::GetFileNameWithoutExtension($sourceFootprintLibrary.Name)
    $rewrittenSymbolBlocks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($block in $sourceSymbolBlocks) {
        $blockLines = [string[]]$block.Lines.Clone()
        for ($index = 0; $index -lt $blockLines.Length; $index++) {
            $propertyMatch = [System.Text.RegularExpressions.Regex]::Match(
                $blockLines[$index],
                '^(\t\t\(property "Footprint" ")([^"]*)("$)'
            )
            if (-not $propertyMatch.Success) {
                continue
            }

            $footprintValue = $propertyMatch.Groups[2].Value
            if ([string]::IsNullOrEmpty($footprintValue)) {
                continue
            }

            $separatorIndex = $footprintValue.IndexOf(':')
            $footprintNickname = ''
            $footprintName = $footprintValue
            if ($separatorIndex -ge 0) {
                $footprintNickname = $footprintValue.Substring(0, $separatorIndex)
                $footprintName = $footprintValue.Substring($separatorIndex + 1)
            }

            $belongsToSource = [string]::IsNullOrEmpty($footprintNickname) -or
                $footprintNickname -eq $sourceFootprintNickname
            if ($footprintNames.ContainsKey($footprintName) -and $belongsToSource) {
                $blockLines[$index] = $propertyMatch.Groups[1].Value + $LibraryName + ':' + $footprintName + $propertyMatch.Groups[3].Value
            }
            elseif ($footprintNickname -eq $sourceFootprintNickname) {
                throw "Symbol '$($block.Name)' references a missing source footprint: $footprintValue"
            }
        }

        $rewrittenSymbolBlocks.Add([PSCustomObject]@{
            Name = $block.Name
            Lines = $blockLines
        })
    }

    $closingIndex = $targetSymbolLines.Length - 1
    while ($closingIndex -ge 0 -and [string]::IsNullOrWhiteSpace($targetSymbolLines[$closingIndex])) {
        $closingIndex--
    }
    if ($closingIndex -lt 0 -or $targetSymbolLines[$closingIndex] -ne ')') {
        throw 'Target symbol library does not have the expected outer closing parenthesis.'
    }

    $mergedLines = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $targetSymbolLines.Length; $index++) {
        if ($index -eq $closingIndex) {
            foreach ($block in $rewrittenSymbolBlocks) {
                foreach ($line in $block.Lines) {
                    [void]$mergedLines.Add($line)
                }
            }
        }
        [void]$mergedLines.Add($targetSymbolLines[$index])
    }

    $newline = if ($targetSymbolText.IndexOf("`r`n", [System.StringComparison]::Ordinal) -ge 0) { "`r`n" } else { "`n" }
    $mergedSymbolText = [System.String]::Join($newline, $mergedLines.ToArray())
    if ($targetSymbolText.EndsWith("`n")) {
        $mergedSymbolText += $newline
    }

    $candidateSymbolLibrary = [System.IO.Path]::Combine($stageRootPath, 'candidate.kicad_sym')
    [System.IO.File]::WriteAllText($candidateSymbolLibrary, $mergedSymbolText, $utf8NoBom)

    $candidateFootprintLibrary = [System.IO.Path]::Combine($stageRootPath, 'candidate.pretty')
    [void][System.IO.Directory]::CreateDirectory($candidateFootprintLibrary)
    foreach ($targetFootprint in @(Get-ChildItem -LiteralPath $targetFootprintLibrary -File -Filter '*.kicad_mod')) {
        [System.IO.File]::Copy(
            $targetFootprint.FullName,
            [System.IO.Path]::Combine($candidateFootprintLibrary, $targetFootprint.Name),
            $false
        )
    }

    $candidateFootprints = New-Object 'System.Collections.Generic.List[object]'
    $sourceModelNameSet = @{}
    foreach ($modelFile in $sourceModelFiles) {
        $sourceModelNameSet[$modelFile.Name] = $true
    }

    foreach ($footprint in $upgradedFootprints) {
        $footprintText = [System.IO.File]::ReadAllText($footprint.FullName, $utf8)
        $modelMatches = [System.Text.RegularExpressions.Regex]::Matches(
            $footprintText,
            '\(model "([^"]+)"'
        )
        if ($null -ne $sourceModelLibrary) {
            $oldPrefix = '../' + $sourceModelLibrary.Name + '/'
            $oldWindowsPrefix = '..' + [char]92 + $sourceModelLibrary.Name + [char]92
            $newPrefix = $targetModelPrefix
            $footprintText = $footprintText.Replace($oldPrefix, $newPrefix)
            $footprintText = $footprintText.Replace($oldWindowsPrefix, $newPrefix)
            if ($footprintText.IndexOf($oldPrefix, [System.StringComparison]::Ordinal) -ge 0) {
                throw "Footprint '$($footprint.Name)' still contains an old 3D model path."
            }
            if ($footprintText.IndexOf($oldWindowsPrefix, [System.StringComparison]::Ordinal) -ge 0) {
                throw "Footprint '$($footprint.Name)' still contains an old 3D model path."
            }

            $modelMatches = [System.Text.RegularExpressions.Regex]::Matches(
                $footprintText,
                '\(model "([^"]+)"'
            )
            foreach ($modelMatch in $modelMatches) {
                $modelReference = $modelMatch.Groups[1].Value
                if (-not $modelReference.StartsWith($targetModelPrefix, [System.StringComparison]::Ordinal)) {
                    throw "Footprint '$($footprint.Name)' has an unsupported 3D model path '$modelReference'. Expected a path under '../$($sourceModelLibrary.Name)/'."
                }
                $modelName = $modelReference.Substring($targetModelPrefix.Length)
                if ($modelName -match '[\\/]') {
                    throw "Footprint '$($footprint.Name)' references a nested 3D model path that is not supported: $modelReference"
                }
                if (-not $sourceModelNameSet.ContainsKey($modelName)) {
                    throw "Footprint '$($footprint.Name)' references a missing model: $modelName"
                }
            }
        }
        elseif ($modelMatches.Count -gt 0) {
            throw "Footprint '$($footprint.Name)' has 3D model references, but the source has no *.3dmodels directory."
        }

        if ($reusedFootprintNames.Contains($footprint.BaseName)) {
            continue
        }

        $candidatePath = [System.IO.Path]::Combine($candidateFootprintLibrary, $footprint.Name)
        [System.IO.File]::WriteAllText($candidatePath, $footprintText, $utf8NoBom)
        $candidateFootprints.Add([PSCustomObject]@{
            Name = $footprint.Name
            Path = $candidatePath
        })
    }

    $validatedSymbolLibrary = [System.IO.Path]::Combine($stageRootPath, 'validated.kicad_sym')
    Invoke-KiCadCli -Arguments @(
        'sym', 'upgrade', $candidateSymbolLibrary,
        '--output', $validatedSymbolLibrary,
        '--force'
    )

    $validatedFootprintLibrary = [System.IO.Path]::Combine($stageRootPath, 'validated.pretty')
    Invoke-KiCadCli -Arguments @(
        'fp', 'upgrade', $candidateFootprintLibrary,
        '--output', $validatedFootprintLibrary,
        '--force'
    )

    $backupDirectory = $null
    $applied = $false
    $description = "$($sourceSymbolBlocks.Count) symbol(s), $($candidateFootprints.Count) new footprint(s), $($reusedFootprintNames.Count) reused footprint(s), $($modelFilesToCopy.Count) new model(s), and $($reusedModelFiles.Count) reused model(s) into '$LibraryName'"
    if ($PSCmdlet.ShouldProcess($projectDirectory, "Import $description")) {
        $backupDirectory = [System.IO.Path]::Combine(
            $projectDirectory,
            '.library_import_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
        )
        [void][System.IO.Directory]::CreateDirectory($backupDirectory)

        $createdPaths = New-Object 'System.Collections.Generic.List[string]'
        $changedTables = New-Object 'System.Collections.Generic.List[object]'
        $symbolReplaced = $false
        try {
            foreach ($tableUpdate in $tableUpdates) {
                if ([System.IO.File]::ReadAllText($tableUpdate.Path, $utf8) -cne $tableUpdate.OriginalText) {
                    throw "Library table changed during import validation: $($tableUpdate.Path)"
                }
                [System.IO.File]::Copy($tableUpdate.Path, [System.IO.Path]::Combine($backupDirectory, $tableUpdate.FileName), $false)
            }
            foreach ($tableUpdate in $tableUpdates) {
                Write-LibraryTableFile -TablePath $tableUpdate.Path -Text $tableUpdate.Text
                $changedTables.Add($tableUpdate)
            }
            if (-not [System.IO.Directory]::Exists($targetModelLibrary)) {
                [void][System.IO.Directory]::CreateDirectory($targetModelLibrary)
            }
            foreach ($modelFile in $modelFilesToCopy) {
                $targetPath = [System.IO.Path]::Combine($targetModelLibrary, $modelFile.Name)
                [System.IO.File]::Copy($modelFile.FullName, $targetPath, $false)
                $createdPaths.Add($targetPath)
            }

            foreach ($candidateFootprint in $candidateFootprints) {
                $targetPath = [System.IO.Path]::Combine($targetFootprintLibrary, $candidateFootprint.Name)
                [System.IO.File]::Copy($candidateFootprint.Path, $targetPath, $false)
                $createdPaths.Add($targetPath)
            }

            $targetTempPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($targetSymbolLibrary),
                '.' + [System.IO.Path]::GetFileName($targetSymbolLibrary) + '.import-' + [Guid]::NewGuid().ToString('N') + '.tmp'
            )
            [System.IO.File]::WriteAllText($targetTempPath, $mergedSymbolText, $utf8NoBom)
            $backupSymbolPath = [System.IO.Path]::Combine($backupDirectory, [System.IO.Path]::GetFileName($targetSymbolLibrary))
            [System.IO.File]::Replace($targetTempPath, $targetSymbolLibrary, $backupSymbolPath, $true)
            $targetTempPath = $null
            $symbolReplaced = $true
            $applied = $true
        }
        catch {
            $importFailure = $_.Exception
            $rollbackFailures = New-Object 'System.Collections.Generic.List[string]'
            if (-not $symbolReplaced) {
                foreach ($changedTable in $changedTables) {
                    try { Write-LibraryTableFile -TablePath $changedTable.Path -RestoreFrom ([System.IO.Path]::Combine($backupDirectory, $changedTable.FileName)) }
                    catch { $rollbackFailures.Add($_.Exception.Message) }
                }
                foreach ($createdPath in $createdPaths) {
                    try { if ([System.IO.File]::Exists($createdPath)) { [System.IO.File]::Delete($createdPath) } }
                    catch { $rollbackFailures.Add($_.Exception.Message) }
                }
            }
            if ($rollbackFailures.Count -gt 0) {
                $importFailure = New-Object System.InvalidOperationException -ArgumentList ($importFailure.Message + ' Rollback failed: ' + [string]::Join('; ', $rollbackFailures.ToArray()))
            }
            $importFailure.Data['Applied'] = ($symbolReplaced -or $rollbackFailures.Count -gt 0)
            $importFailure.Data['BackupDirectory'] = $backupDirectory
            throw $importFailure
        }
    }

    [PSCustomObject]@{
        Applied = $applied
        LibraryName = $LibraryName
        Symbols = [System.String]::Join(', ', @($sourceSymbolBlocks | ForEach-Object { $_.Name }))
        Footprints = [System.String]::Join(', ', @($upgradedFootprints | ForEach-Object { $_.BaseName }))
        ReusedFootprints = [System.String]::Join(', ', $reusedFootprintNames.ToArray())
        Models = [System.String]::Join(', ', @($sourceModelFiles | ForEach-Object { $_.Name }))
        ReusedModels = [System.String]::Join(', ', $reusedModelFiles.ToArray())
        BackupDirectory = $backupDirectory
        SymbolNames = [string[]]@($sourceSymbolBlocks | ForEach-Object { $_.Name })
        FootprintNames = [string[]]@($upgradedFootprints | ForEach-Object { $_.BaseName })
        ReusedFootprintNames = [string[]]$reusedFootprintNames.ToArray()
        ModelNames = [string[]]@($sourceModelFiles | ForEach-Object { $_.Name })
        ReusedModelNames = [string[]]$reusedModelFiles.ToArray()
    }
}
finally {
    foreach ($tableLock in $tableLocks) {
        $tableLock.ReleaseMutex()
        $tableLock.Dispose()
    }
    foreach ($tableTemporaryPath in $tableTemporaryPaths) {
        if ([System.IO.File]::Exists($tableTemporaryPath)) { [System.IO.File]::Delete($tableTemporaryPath) }
    }
    if ($null -ne $targetTempPath -and [System.IO.File]::Exists($targetTempPath)) {
        [System.IO.File]::Delete($targetTempPath)
    }

    if ($null -ne $stageRootPath -and [System.IO.Directory]::Exists($stageRootPath)) {
        $projectFullPath = [System.IO.Path]::GetFullPath($projectDirectory).TrimEnd([char]92)
        $stageFullPath = [System.IO.Path]::GetFullPath($stageRootPath).TrimEnd([char]92)
        $projectPrefix = $projectFullPath + [System.IO.Path]::DirectorySeparatorChar
        $stageItem = Get-Item -LiteralPath $stageFullPath
        if (($stageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warning "Refusing to delete a staging directory that became a reparse point: $stageFullPath"
        }
        elseif ($stageFullPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.IO.Directory]::Delete($stageFullPath, $true)
        }
        else {
            Write-Warning "Refusing to delete staging directory outside ProjectRoot: $stageFullPath"
        }
    }
}
