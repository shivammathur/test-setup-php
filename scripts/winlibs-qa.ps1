param(
    [string] $BuilderRepository = "shivammathur/php-windows-builder",
    [string] $BuilderRunIds = "",
    [int] $LatestBuilderRuns = 5,
    [string] $Series = "",
    [string] $OfficialSeries = "8.2,8.3,8.4,8.5",
    [string] $Variants = "x64-ts,x64-nts,x86-ts,x86-nts",
    [string] $WorkDir = ".qa",
    [switch] $SkipOfficial
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

$ReleaseBase = "https://downloads.php.net/~windows/releases"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot
$FunctionalTest = Join-Path $RepoRoot "tests/winlibs-functional.php"
$DownloadDir = Join-Path $WorkDir "downloads"
$ExtractDir = Join-Path $WorkDir "extracted"
$ReportDir = Join-Path $WorkDir "report"
$SystemDllPattern = '^(api-ms-win-.*|ext-ms-.*|advapi32|bcrypt|comctl32|comdlg32|crypt32|dnsapi|gdi32|imm32|iphlpapi|kernel32|msvcp140|normaliz|ole32|oleaut32|rpcrt4|secur32|shell32|shlwapi|ucrtbase|user32|version|vcruntime140|vcruntime140_1|winmm|wldap32|ws2_32)\.dll$'

function New-CleanDirectory([string] $Path) {
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function Split-List([string] $Value) {
    @($Value -split "[,\s]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-RunMatchesSeries($Run, [string[]] $SeriesList) {
    $seriesItems = @($SeriesList)
    if ($seriesItems.Count -eq 0) {
        return $true
    }
    foreach ($seriesName in $seriesItems) {
        if ($seriesName -eq "8.6") {
            if ($Run.displayTitle -like "*master*" -or $Run.displayTitle -like "*PHP-8.6*") {
                return $true
            }
        } elseif ($Run.displayTitle -like "*PHP-$seriesName*") {
            return $true
        }
    }
    return $false
}

function Get-Dumpbin {
    $candidates = @()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installPath) {
            $candidates += Get-ChildItem -Path (Join-Path $installPath "VC\Tools\MSVC") -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\bin\\Hostx64\\x64\\dumpbin\.exe$" } |
                Sort-Object FullName -Descending
        }
    }
    $pathCandidate = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($pathCandidate) {
        $candidates += Get-Item $pathCandidate.Source
    }
    $dumpbin = @($candidates | Select-Object -First 1)
    if ($dumpbin.Count -eq 0) {
        throw "dumpbin.exe was not found. Visual Studio C++ tools are required on the runner."
    }
    return $dumpbin[0].FullName
}

function Get-RunList {
    if (-not [string]::IsNullOrWhiteSpace($BuilderRunIds)) {
        $ids = Split-List $BuilderRunIds
        $runs = @($ids | ForEach-Object {
            $run = gh run view $_ -R $BuilderRepository --json databaseId,displayTitle,createdAt,url,conclusion | ConvertFrom-Json
            [pscustomobject]@{
                databaseId = [string] $run.databaseId
                displayTitle = $run.displayTitle
                createdAt = $run.createdAt
                url = $run.url
                conclusion = $run.conclusion
            }
        })
        return @($runs | Where-Object { Test-RunMatchesSeries -Run $_ -SeriesList $SelectedSeries })
    }

    $runs = gh run list -R $BuilderRepository --limit 50 --json databaseId,displayTitle,createdAt,url,conclusion,workflowName | ConvertFrom-Json
    return @($runs |
        Where-Object { $_.conclusion -eq "success" -and $_.displayTitle -like "Build PHP from source*" } |
        ForEach-Object {
            [pscustomobject]@{
                databaseId = [string] $_.databaseId
                displayTitle = $_.displayTitle
                createdAt = $_.createdAt
                url = $_.url
                conclusion = $_.conclusion
            }
        } |
        Where-Object { Test-RunMatchesSeries -Run $_ -SeriesList $SelectedSeries } |
        Select-Object -First $LatestBuilderRuns)
}

function Get-PhpZipInfo([System.IO.FileInfo] $Zip, [string] $Source, $Run) {
    $zipMatch = [regex]::Match($Zip.Name, '^php-(?<version>.+?)-(?<nts>nts-)?Win32-(?<vs>vs\d+)-(?<arch>x64|x86)\.zip$')
    if (-not $zipMatch.Success) {
        return $null
    }
    $version = $zipMatch.Groups["version"].Value
    $seriesMatch = [regex]::Match($version, '^(\d+\.\d+)')
    $series = if ($seriesMatch.Success) { $seriesMatch.Groups[1].Value } else { "unknown" }
    $threadSafety = if ($zipMatch.Groups["nts"].Success -and $zipMatch.Groups["nts"].Value) { "nts" } else { "ts" }
    $arch = $zipMatch.Groups["arch"].Value
    $vs = $zipMatch.Groups["vs"].Value
    $variant = "$arch-$threadSafety"
    [pscustomobject]@{
        source = $Source
        runId = if ($Run) { [string] $Run.databaseId } else { $null }
        runTitle = if ($Run) { $Run.displayTitle } else { "official $series" }
        runUrl = if ($Run) { $Run.url } else { $null }
        zip = $Zip.FullName
        zipName = $Zip.Name
        version = $version
        series = $series
        arch = $arch
        threadSafety = $threadSafety
        variant = $variant
        vs = $vs
        key = "$series|$variant"
    }
}

function Download-BuilderArtifacts($Runs) {
    $subjects = @()
    foreach ($run in $Runs) {
        $runDir = Join-Path $DownloadDir "builder-$($run.databaseId)"
        New-Item -Path $runDir -ItemType Directory -Force | Out-Null
        Write-Host "Downloading builder artifacts from $($run.databaseId) ($($run.displayTitle))"
        gh run download $run.databaseId -R $BuilderRepository -n artifacts -D $runDir
        $zips = Get-ChildItem -Path $runDir -Filter "php-*.zip" -File |
            Where-Object { $_.Name -notmatch 'debug-pack|devel-pack|test-pack|src' }
        foreach ($zip in $zips) {
            $info = Get-PhpZipInfo -Zip $zip -Source "builder" -Run $run
            if ($info) {
                $subjects += $info
            }
        }
    }
    return $subjects
}

function Download-OfficialArtifacts([string[]] $SeriesList) {
    $subjects = @()
    $seriesItems = @($SeriesList)
    if ($seriesItems.Count -eq 0) {
        $seriesItems = @(Split-List $OfficialSeries)
    }
    $variantList = Split-List $Variants
    Write-Host "Fetching official PHP Windows release index"
    $index = Invoke-RestMethod -Uri "$ReleaseBase/releases.json"
    $officialDir = Join-Path $DownloadDir "official"
    New-Item -Path $officialDir -ItemType Directory -Force | Out-Null

    foreach ($series in $seriesItems) {
        $seriesEntry = $index.PSObject.Properties[$series].Value
        if (-not $seriesEntry) {
            throw "Official release series $series was not found in releases.json"
        }
        foreach ($variant in $variantList) {
            $variantMatch = [regex]::Match($variant, '^(?<arch>x64|x86)-(?<ts>ts|nts)$')
            if (-not $variantMatch.Success) {
                throw "Invalid variant '$variant'. Use values like x64-ts or x86-nts."
            }
            $arch = $variantMatch.Groups["arch"].Value
            $ts = $variantMatch.Groups["ts"].Value
            $key = @($seriesEntry.PSObject.Properties.Name |
                Where-Object { $_ -match "^$ts-vs\d+-$arch$" } |
                Sort-Object { [int]($_ -replace '^.*-vs(\d+)-.*$', '$1') } -Descending |
                Select-Object -First 1)
            if ($key.Count -eq 0) {
                throw "No official Windows build found for $series $variant"
            }
            $build = $seriesEntry.PSObject.Properties[$key[0]].Value
            $path = $build.zip.path
            $target = Join-Path $officialDir $path
            if (-not (Test-Path $target)) {
                Write-Host "Downloading official $series $variant from $path"
                Invoke-WebRequest -Uri "$ReleaseBase/$path" -OutFile $target
            }
            $info = Get-PhpZipInfo -Zip (Get-Item $target) -Source "official" -Run $null
            if ($info) {
                $subjects += $info
            }
        }
    }
    return $subjects
}

function Find-PhpRoot([string] $Path) {
    $php = Get-ChildItem -Path $Path -Recurse -Filter php.exe -File | Select-Object -First 1
    if (-not $php) {
        throw "php.exe not found after extracting $Path"
    }
    return Split-Path -Parent $php.FullName
}

function Invoke-PhpCommand([string] $PhpRoot, [string[]] $Arguments) {
    $php = Join-Path $PhpRoot "php.exe"
    $oldPath = $env:PATH
    $oldPhpRoot = $env:WINLIBS_PHP_ROOT
    $oldProgress = $env:WINLIBS_QA_PROGRESS
    $env:PATH = "$PhpRoot;$(Join-Path $PhpRoot 'ext');$oldPath"
    $env:WINLIBS_PHP_ROOT = $PhpRoot
    $env:WINLIBS_QA_PROGRESS = "1"
    try {
        Push-Location $PhpRoot
        $output = & $php @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        Pop-Location
    } finally {
        $env:PATH = $oldPath
        $env:WINLIBS_PHP_ROOT = $oldPhpRoot
        $env:WINLIBS_QA_PROGRESS = $oldProgress
    }
    [pscustomobject]@{
        exitCode = $exitCode
        output = @($output | ForEach-Object { $_.ToString() })
    }
}

function Get-ModuleList($Output) {
    @($Output | Where-Object { $_ -and $_ -notmatch '^\[' } | Sort-Object -Unique)
}

function Get-PhpIniSnapshot([string] $PhpRoot) {
    $info = Invoke-PhpCommand -PhpRoot $PhpRoot -Arguments @("-n", "-i")
    $keys = @(
        "PHP Version",
        "System",
        "Build Date",
        "Compiler",
        "Architecture",
        "Configure Command",
        "Thread Safety",
        "Loaded Configuration File",
        "Scan this dir for additional .ini files",
        "extension_dir"
    )
    $snapshot = [ordered]@{}
    foreach ($line in $info.output) {
        foreach ($key in $keys) {
            if ($line -like "$key =>*") {
                $snapshot[$key] = ($line -replace ("^" + [regex]::Escape($key) + " =>\s*"), "")
            }
        }
    }
    return $snapshot
}

function Get-PhpIniTemplateSnapshot([string] $PhpRoot) {
    $templates = [ordered]@{}
    foreach ($name in @("php.ini-development", "php.ini-production")) {
        $path = Join-Path $PhpRoot $name
        if (-not (Test-Path $path)) {
            $templates[$name] = [pscustomobject]@{
                exists = $false
                targetLines = @()
                gettextExtensionConfigured = $false
                enchantExtensionConfigured = $false
            }
            continue
        }

        $lines = Get-Content -LiteralPath $path
        $targetLines = @($lines | Where-Object { $_ -match '(?i)gettext|enchant|glib|libintl' })
        $gettextLine = @($lines | Where-Object { $_ -match '^\s*;?\s*extension\s*=\s*(php_)?gettext(\.dll)?\s*$' })
        $enchantLine = @($lines | Where-Object { $_ -match '^\s*;?\s*extension\s*=\s*(php_)?enchant(\.dll)?\s*$' })
        $templates[$name] = [pscustomobject]@{
            exists = $true
            targetLines = $targetLines
            gettextExtensionConfigured = $gettextLine.Count -gt 0
            enchantExtensionConfigured = $enchantLine.Count -gt 0
        }
    }
    return $templates
}

function ConvertTo-ComparableJson($Value) {
    if ($null -eq $Value) {
        return "null"
    }
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-FunctionalCheckMap($Functional) {
    $map = @{}
    if ($null -eq $Functional -or $null -eq $Functional.checks) {
        return $map
    }
    foreach ($check in @($Functional.checks)) {
        $map[$check.name] = $check
    }
    return $map
}

function Get-FunctionalFailureNames($Functional) {
    if ($null -eq $Functional -or $null -eq $Functional.failures) {
        return @()
    }
    @($Functional.failures | ForEach-Object { $_.name } | Sort-Object -Unique)
}

function Read-FunctionalResult([string] $Path) {
    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            result = $null
            error = "Functional JSON was not created"
        }
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            result = $null
            error = "Functional JSON was empty"
        }
    }

    try {
        return [pscustomobject]@{
            result = ($raw | ConvertFrom-Json -ErrorAction Stop)
            error = $null
        }
    } catch {
        return [pscustomobject]@{
            result = $null
            error = "Functional JSON could not be parsed: $($_.Exception.Message)"
        }
    }
}

function Write-FunctionalCheckLog([string] $SubjectId, $FunctionalResult, [int] $ExitCode, [string] $ParseError, [string[]] $Output) {
    Write-Host "::group::Functional tests: $SubjectId"
    Write-Host "Functional PHP exit code: $ExitCode"
    if (-not [string]::IsNullOrWhiteSpace($ParseError)) {
        Write-Host "Functional JSON parse status: $ParseError"
        $outputLines = @($Output)
        if ($outputLines.Count -gt 0) {
            Write-Host "Captured functional output before failure:"
            foreach ($line in $outputLines) {
                Write-Host $line
            }
        }
    }

    if ($null -eq $FunctionalResult) {
        Write-Host "No functional checks were available."
        Write-Host "::endgroup::"
        return
    }

    $checks = @($FunctionalResult.checks)
    $failures = @($FunctionalResult.failures)
    Write-Host "Functional checks run: $($checks.Count)"
    Write-Host "Raw functional observations: $($failures.Count)"
    foreach ($check in $checks) {
        $status = if ($check.ok -eq $true) { "PASS" } else { "OBSERVED" }
        Write-Host ("[{0}] {1}" -f $status, $check.name)
        $details = $check.PSObject.Properties["details"]
        if ($check.ok -ne $true -and $null -ne $details) {
            Write-Host ("    details: {0}" -f (ConvertTo-ComparableJson $details.Value))
        }
    }
    Write-Host "::endgroup::"
}

function Get-Dependents([string] $Dumpbin, [string] $File) {
    $output = & $Dumpbin /dependents $File 2>&1
    $deps = @()
    foreach ($line in $output) {
        $trimmed = $line.ToString().Trim()
        if ($trimmed -match '^[A-Za-z0-9_.+-]+\.dll$') {
            $deps += $trimmed
        }
    }
    return @($deps | Sort-Object -Unique)
}

function Test-DependencyClosure([string] $PhpRoot, [string] $Dumpbin) {
    $provided = @{}
    Get-ChildItem -Path $PhpRoot -Filter "*.dll" -File | ForEach-Object { $provided[$_.Name.ToLowerInvariant()] = $_.FullName }
    $extDir = Join-Path $PhpRoot "ext"
    if (Test-Path $extDir) {
        Get-ChildItem -Path $extDir -Filter "*.dll" -File | ForEach-Object { $provided[$_.Name.ToLowerInvariant()] = $_.FullName }
    }

    $targetNames = @(
        "ext\php_gettext.dll",
        "ext\php_enchant.dll",
        "libintl.dll",
        "libenchant2.dll",
        "lib\enchant\libenchant2_hunspell.dll",
        "glib-2.dll",
        "gmodule-2.dll",
        "gobject-2.dll",
        "gio-2.dll",
        "gthread-2.dll"
    )

    $imports = [ordered]@{}
    $missing = @()
    $expected = @()
    foreach ($target in $targetNames) {
        $file = Join-Path $PhpRoot $target
        if (-not (Test-Path $file)) {
            continue
        }
        $deps = Get-Dependents -Dumpbin $Dumpbin -File $file
        $imports[$target] = $deps
        foreach ($dep in $deps) {
            $key = $dep.ToLowerInvariant()
            if (-not $provided.ContainsKey($key) -and $key -notmatch $SystemDllPattern) {
                $missing += [pscustomobject]@{ binary = $target; dependency = $dep }
            }
        }
    }

    if ($imports.Contains("ext\php_enchant.dll") -and ($imports["ext\php_enchant.dll"] -notcontains "libenchant2.dll")) {
        $expected += "php_enchant.dll does not import libenchant2.dll"
    }
    if ($imports.Contains("libenchant2.dll")) {
        foreach ($dep in @("glib-2.dll", "gmodule-2.dll", "gobject-2.dll")) {
            if ($imports["libenchant2.dll"] -notcontains $dep) {
                $expected += "libenchant2.dll does not import $dep"
            }
        }
    }

    [pscustomobject]@{
        imports = $imports
        missing = @($missing)
        expectedImportIssues = @($expected)
    }
}

function Test-Subject($Subject, [string] $Dumpbin) {
    $id = "$($Subject.source)-$($Subject.version)-$($Subject.variant)"
    $subjectDir = Join-Path $ExtractDir ($id -replace '[^A-Za-z0-9_.-]', '_')
    New-CleanDirectory $subjectDir
    Write-Host "Extracting $($Subject.zipName)"
    Expand-Archive -Path $Subject.zip -DestinationPath $subjectDir -Force
    $phpRoot = Find-PhpRoot $subjectDir
    $extDir = Join-Path $phpRoot "ext"
    $reportSubjectDir = Join-Path $ReportDir $id
    New-Item -Path $reportSubjectDir -ItemType Directory -Force | Out-Null

    $required = @(
        "php.exe",
        "php.ini-development",
        "php.ini-production",
        "ext\php_gettext.dll",
        "ext\php_enchant.dll",
        "libenchant2.dll",
        "lib\enchant\libenchant2_hunspell.dll",
        "glib-2.dll",
        "gmodule-2.dll",
        "gobject-2.dll"
    )
    $missingFiles = @($required | Where-Object { -not (Test-Path (Join-Path $phpRoot $_)) })

    $extensionArgs = @("-n", "-d", "extension_dir=$extDir", "-d", "extension=gettext", "-d", "extension=enchant")
    $moduleBase = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments @("-n", "-m")
    $moduleDefault = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments @("-m")
    $moduleTarget = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments ($extensionArgs + @("-m"))
    $gettextInfo = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments ($extensionArgs + @("--ri", "gettext"))
    $enchantInfo = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments ($extensionArgs + @("--ri", "enchant"))
    $functionalJson = Join-Path $reportSubjectDir "functional.json"
    $functional = Invoke-PhpCommand -PhpRoot $phpRoot -Arguments ($extensionArgs + @($FunctionalTest, "--json-out", $functionalJson))
    Set-Content -Path (Join-Path $reportSubjectDir "functional-output.txt") -Value $functional.output
    $functionalRead = Read-FunctionalResult -Path $functionalJson
    $functionalResult = $functionalRead.result
    Write-FunctionalCheckLog -SubjectId $id -FunctionalResult $functionalResult -ExitCode $functional.exitCode -ParseError $functionalRead.error -Output $functional.output
    $deps = Test-DependencyClosure -PhpRoot $phpRoot -Dumpbin $Dumpbin
    $iniSnapshot = Get-PhpIniSnapshot -PhpRoot $phpRoot
    $iniTemplates = Get-PhpIniTemplateSnapshot -PhpRoot $phpRoot

    Set-Content -Path (Join-Path $reportSubjectDir "php-m-base.txt") -Value $moduleBase.output
    Set-Content -Path (Join-Path $reportSubjectDir "php-m-default.txt") -Value $moduleDefault.output
    Set-Content -Path (Join-Path $reportSubjectDir "php-m-target.txt") -Value $moduleTarget.output
    Set-Content -Path (Join-Path $reportSubjectDir "php-ri-gettext.txt") -Value $gettextInfo.output
    Set-Content -Path (Join-Path $reportSubjectDir "php-ri-enchant.txt") -Value $enchantInfo.output

    $issues = @()
    foreach ($file in $missingFiles) {
        $issues += [pscustomobject]@{ level = "error"; message = "Missing expected file: $file" }
    }
    foreach ($missing in $deps.missing) {
        $issues += [pscustomobject]@{ level = "error"; message = "Missing dependency for $($missing.binary): $($missing.dependency)" }
    }
    foreach ($expected in $deps.expectedImportIssues) {
        $issues += [pscustomobject]@{ level = "error"; message = $expected }
    }
    if ($moduleTarget.exitCode -ne 0) {
        $issues += [pscustomobject]@{ level = "error"; message = "Target extensions did not load cleanly" }
    }
    if (-not [string]::IsNullOrWhiteSpace($functionalRead.error)) {
        $issues += [pscustomobject]@{ level = "error"; message = $functionalRead.error }
    } elseif ($null -eq $functionalResult -or $null -eq $functionalResult.checks -or @($functionalResult.checks).Count -eq 0) {
        $issues += [pscustomobject]@{ level = "error"; message = "Functional PHP test reported zero checks" }
    }

    [pscustomobject]@{
        id = $id
        source = $Subject.source
        runId = $Subject.runId
        runTitle = $Subject.runTitle
        runUrl = $Subject.runUrl
        zipName = $Subject.zipName
        version = $Subject.version
        series = $Subject.series
        arch = $Subject.arch
        threadSafety = $Subject.threadSafety
        variant = $Subject.variant
        vs = $Subject.vs
        key = $Subject.key
        phpRoot = $phpRoot
        gettextLinkage = if ($deps.imports.Contains("ext\php_gettext.dll") -and ($deps.imports["ext\php_gettext.dll"] -contains "libintl.dll")) { "dynamic-libintl" } else { "static-or-no-libintl-import" }
        missingFiles = @($missingFiles)
        dependencyImports = $deps.imports
        missingDependencies = $deps.missing
        expectedImportIssues = $deps.expectedImportIssues
        ini = $iniSnapshot
        iniTemplates = $iniTemplates
        modulesBase = Get-ModuleList $moduleBase.output
        modulesDefault = Get-ModuleList $moduleDefault.output
        modulesTarget = Get-ModuleList $moduleTarget.output
        gettextInfoExitCode = $gettextInfo.exitCode
        enchantInfoExitCode = $enchantInfo.exitCode
        functionalCheckCount = if ($functionalResult -and $functionalResult.checks) { @($functionalResult.checks).Count } else { 0 }
        functionalFailureCount = if ($functionalResult -and $functionalResult.failures) { @($functionalResult.failures).Count } else { 0 }
        functionalExitCode = $functional.exitCode
        functional = $functionalResult
        issues = @($issues)
    }
}

function Compare-Subjects($BuilderSubjects, $OfficialSubjects) {
    $comparisons = @()
    foreach ($builder in $BuilderSubjects) {
        if ($builder.series -eq "8.6") {
            continue
        }
        $official = @($OfficialSubjects | Where-Object { $_.key -eq $builder.key } | Select-Object -First 1)
        if ($official.Count -eq 0) {
            $comparisons += [pscustomobject]@{
                key = $builder.key
                status = "missing-official"
                issues = @("No official baseline found")
            }
            continue
        }
        $issues = @()
        foreach ($file in @("ext\php_gettext.dll", "ext\php_enchant.dll", "libenchant2.dll", "lib\enchant\libenchant2_hunspell.dll", "glib-2.dll", "gmodule-2.dll", "gobject-2.dll")) {
            if (($builder.missingFiles -contains $file) -and -not ($official[0].missingFiles -contains $file)) {
                $issues += "Builder missing $file while official has it"
            }
        }
        if ($builder.gettextLinkage -ne $official[0].gettextLinkage) {
            $issues += "gettext linkage drift: builder='$($builder.gettextLinkage)' official='$($official[0].gettextLinkage)'"
        }
        foreach ($binary in @("ext\php_gettext.dll", "ext\php_enchant.dll", "libenchant2.dll", "lib\enchant\libenchant2_hunspell.dll", "glib-2.dll")) {
            $builderImports = if ($builder.dependencyImports.Contains($binary)) { @($builder.dependencyImports[$binary] | Where-Object { $_ -notmatch $SystemDllPattern }) } else { @() }
            $officialImports = if ($official[0].dependencyImports.Contains($binary)) { @($official[0].dependencyImports[$binary] | Where-Object { $_ -notmatch $SystemDllPattern }) } else { @() }
            $added = @($builderImports | Where-Object { $officialImports -notcontains $_ })
            $removed = @($officialImports | Where-Object { $builderImports -notcontains $_ })
            if ($added.Count -gt 0 -or $removed.Count -gt 0) {
                $issues += "${binary} import drift: added=[$($added -join ', ')] removed=[$($removed -join ', ')]"
            }
        }
        $builderFunctionalFailures = Get-FunctionalFailureNames $builder.functional
        $officialFunctionalFailures = Get-FunctionalFailureNames $official[0].functional
        $newFunctionalFailures = @($builderFunctionalFailures | Where-Object { $officialFunctionalFailures -notcontains $_ })
        if ($newFunctionalFailures.Count -gt 0) {
            $issues += "Builder has functional failures not present in official: [$($newFunctionalFailures -join ', ')]"
        }
        $builderCheckMap = Get-FunctionalCheckMap $builder.functional
        $officialCheckMap = Get-FunctionalCheckMap $official[0].functional
        foreach ($checkName in @($officialCheckMap.Keys | Sort-Object)) {
            if (-not $builderCheckMap.ContainsKey($checkName)) {
                $issues += "Builder functional check missing: $checkName"
                continue
            }
            if ($officialCheckMap[$checkName].ok -eq $true -and $builderCheckMap[$checkName].ok -ne $true) {
                $issues += "Builder failed functional check that official passed: $checkName"
            }
        }
        foreach ($checkName in @($builderCheckMap.Keys | Sort-Object)) {
            if (-not $officialCheckMap.ContainsKey($checkName)) {
                $issues += "Builder functional check has no official baseline: $checkName"
            }
        }
        foreach ($detailKey in @("gettext_c_utf8_behavior", "gettext_latin1_conversion_behavior", "gettext_locale_switch_behavior", "gettext_unicode_path_behavior", "enchant_default_provider_names", "enchant_provider_names", "enchant_installed_dictionary_languages", "enchant_configured_hunspell_available")) {
            $builderDetail = if ($builder.functional -and $builder.functional.details) { $builder.functional.details.$detailKey } else { $null }
            $officialDetail = if ($official[0].functional -and $official[0].functional.details) { $official[0].functional.details.$detailKey } else { $null }
            if ((ConvertTo-ComparableJson $builderDetail) -ne (ConvertTo-ComparableJson $officialDetail)) {
                $issues += "Functional detail drift for ${detailKey}: builder='$(ConvertTo-ComparableJson $builderDetail)' official='$(ConvertTo-ComparableJson $officialDetail)'"
            }
        }
        $configKeys = @("Thread Safety", "Architecture", "extension_dir")
        foreach ($key in $configKeys) {
            $builderValue = $builder.ini[$key]
            $officialValue = $official[0].ini[$key]
            if ($builderValue -ne $officialValue) {
                $issues += "Config drift for ${key}: builder='$builderValue' official='$officialValue'"
            }
        }
        foreach ($templateName in @("php.ini-development", "php.ini-production")) {
            $builderTemplate = $builder.iniTemplates[$templateName]
            $officialTemplate = $official[0].iniTemplates[$templateName]
            if ($builderTemplate.exists -ne $officialTemplate.exists) {
                $issues += "php.ini template drift for ${templateName}: builder exists='$($builderTemplate.exists)' official exists='$($officialTemplate.exists)'"
                continue
            }
            if ($builderTemplate.gettextExtensionConfigured -ne $officialTemplate.gettextExtensionConfigured) {
                $issues += "php.ini template drift for ${templateName}: gettext extension entry builder='$($builderTemplate.gettextExtensionConfigured)' official='$($officialTemplate.gettextExtensionConfigured)'"
            }
            if ($builderTemplate.enchantExtensionConfigured -ne $officialTemplate.enchantExtensionConfigured) {
                $issues += "php.ini template drift for ${templateName}: enchant extension entry builder='$($builderTemplate.enchantExtensionConfigured)' official='$($officialTemplate.enchantExtensionConfigured)'"
            }
            $builderTargetLines = @($builderTemplate.targetLines)
            $officialTargetLines = @($officialTemplate.targetLines)
            $addedTemplateLines = @($builderTargetLines | Where-Object { $officialTargetLines -notcontains $_ })
            $removedTemplateLines = @($officialTargetLines | Where-Object { $builderTargetLines -notcontains $_ })
            if ($addedTemplateLines.Count -gt 0 -or $removedTemplateLines.Count -gt 0) {
                $issues += "php.ini target-line drift for ${templateName}: added=[$($addedTemplateLines -join ' | ')] removed=[$($removedTemplateLines -join ' | ')]"
            }
        }
        $builderModules = @($builder.modulesTarget | Sort-Object -Unique)
        $officialModules = @($official[0].modulesTarget | Sort-Object -Unique)
        foreach ($module in @("gettext", "enchant")) {
            if (($builderModules -notcontains $module) -and ($officialModules -contains $module)) {
                $issues += "Builder target module missing: $module"
            }
        }
        $builderDefaultModules = @($builder.modulesDefault | Sort-Object -Unique)
        $officialDefaultModules = @($official[0].modulesDefault | Sort-Object -Unique)
        foreach ($module in @("gettext", "enchant")) {
            if (($builderDefaultModules -contains $module) -ne ($officialDefaultModules -contains $module)) {
                $issues += "Default module load drift for ${module}: builder='$($builderDefaultModules -contains $module)' official='$($officialDefaultModules -contains $module)'"
            }
        }
        $comparisons += [pscustomobject]@{
            key = $builder.key
            builder = $builder.id
            official = $official[0].id
            status = if ($issues.Count -eq 0) { "ok" } else { "drift" }
            issues = @($issues)
            builderFunctionalFailures = $builderFunctionalFailures
            officialFunctionalFailures = $officialFunctionalFailures
        }
    }
    return $comparisons
}

function Write-FunctionalComparisonLog($BuilderSubjects, $OfficialSubjects, $Comparisons) {
    foreach ($builder in $BuilderSubjects) {
        Write-Host "::group::Functional failure comparison: $($builder.id)"
        $builderFailures = @(Get-FunctionalFailureNames $builder.functional)

        $official = @($OfficialSubjects | Where-Object { $_.key -eq $builder.key } | Select-Object -First 1)
        if ($official.Count -eq 0) {
            Write-Host "No official baseline for this builder artifact."
            Write-Host "Fails on our builds only: $($builderFailures.Count)"
            foreach ($name in $builderFailures) {
                Write-Host "  - $name"
            }
            Write-Host "::endgroup::"
            continue
        }

        $comparison = @($Comparisons | Where-Object { $_.builder -eq $builder.id } | Select-Object -First 1)
        if ($comparison.Count -gt 0) {
            Write-Host "Comparison status: $($comparison[0].status)"
        }
        $officialFailures = @(Get-FunctionalFailureNames $official[0].functional)
        $failsOnBoth = @($builderFailures | Where-Object { $officialFailures -contains $_ })
        $failsOnOfficialOnly = @($officialFailures | Where-Object { $builderFailures -notcontains $_ })
        $failsOnOurBuildsOnly = @($builderFailures | Where-Object { $officialFailures -notcontains $_ })

        Write-Host "Fails on both: $($failsOnBoth.Count)"
        foreach ($name in $failsOnBoth) {
            Write-Host "  - $name"
        }
        Write-Host "Fails on official only: $($failsOnOfficialOnly.Count)"
        foreach ($name in $failsOnOfficialOnly) {
            Write-Host "  - $name"
        }
        Write-Host "Fails on our builds only: $($failsOnOurBuildsOnly.Count)"
        foreach ($name in $failsOnOurBuildsOnly) {
            Write-Host "  - $name"
        }
        Write-Host "::endgroup::"
    }
}

function Write-MarkdownReport($Summary, [string] $Path) {
    $lines = @()
    $lines += "# Winlibs PHP Artifact QA"
    $lines += ""
    $lines += "Generated: $($Summary.generatedAt)"
    $lines += ""
    $lines += "## Subjects"
    $lines += ""
    $lines += "| Source | Version | Variant | VS | Functional checks | Raw functional observations | Missing files | Missing deps | Issues |"
    $lines += "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |"
    foreach ($subject in $Summary.subjects) {
        $lines += "| $($subject.source) | $($subject.version) | $($subject.variant) | $($subject.vs) | $($subject.functionalCheckCount) | $($subject.functionalFailureCount) | $($subject.missingFiles.Count) | $($subject.missingDependencies.Count) | $($subject.issues.Count) |"
    }
    $lines += ""
    $lines += "## Comparisons"
    $lines += ""
    $lines += "| Key | Status | Issues |"
    $lines += "| --- | --- | --- |"
    foreach ($comparison in $Summary.comparisons) {
        $issueText = if ($comparison.issues.Count -eq 0) { "" } else { ($comparison.issues -join "<br>") }
        $lines += "| $($comparison.key) | $($comparison.status) | $issueText |"
    }
    $functionalCheckNames = @(
        $Summary.subjects |
            Where-Object { $null -ne $_.functional -and $null -ne $_.functional.checks } |
            ForEach-Object { $_.functional.checks } |
            ForEach-Object { $_.name } |
            Sort-Object -Unique
    )
    if ($functionalCheckNames.Count -gt 0) {
        $lines += ""
        $lines += "## Functional Checks Run"
        $lines += ""
        foreach ($checkName in $functionalCheckNames) {
            $lines += "- $checkName"
        }
    }
    Set-Content -Path $Path -Value $lines
}

New-CleanDirectory $DownloadDir
New-CleanDirectory $ExtractDir
New-CleanDirectory $ReportDir

if (-not (Test-Path $FunctionalTest)) {
    throw "Functional test file not found: $FunctionalTest"
}

$SelectedSeries = @(Split-List $Series)
if ($SelectedSeries.Count -gt 0) {
    Write-Host "Selected PHP series: $($SelectedSeries -join ', ')"
}

$dumpbin = Get-Dumpbin
Write-Host "Using dumpbin: $dumpbin"

$runs = Get-RunList
if ($runs.Count -eq 0) {
    throw "No builder runs selected"
}

$builderZipSubjects = Download-BuilderArtifacts -Runs $runs
$builderZipSubjects = @($builderZipSubjects | Where-Object { $SelectedSeries.Count -eq 0 -or $SelectedSeries -contains $_.series })
if ($builderZipSubjects.Count -eq 0) {
    throw "No PHP runtime zips found in selected builder artifacts"
}

$officialZipSubjects = @()
if (-not $SkipOfficial) {
    $officialSeriesList = @(Split-List $OfficialSeries)
    if ($SelectedSeries.Count -gt 0) {
        $officialSeriesList = @($officialSeriesList | Where-Object { $SelectedSeries -contains $_ })
    }
    $officialSeriesList = @($officialSeriesList | Where-Object { $_ -ne "8.6" })
    if ($officialSeriesList.Count -gt 0) {
        $officialZipSubjects = Download-OfficialArtifacts -SeriesList $officialSeriesList
    } else {
        Write-Host "Skipping official PHP downloads for selected series"
    }
}

$selectedVariants = Split-List $Variants
$builderZipSubjects = @($builderZipSubjects | Where-Object { $selectedVariants -contains $_.variant })
$officialZipSubjects = @($officialZipSubjects | Where-Object { $selectedVariants -contains $_.variant })

$subjectSummaries = @()
foreach ($subject in @($builderZipSubjects + $officialZipSubjects)) {
    $subjectSummaries += Test-Subject -Subject $subject -Dumpbin $dumpbin
}

$builderSummaries = @($subjectSummaries | Where-Object { $_.source -eq "builder" })
$officialSummaries = @($subjectSummaries | Where-Object { $_.source -eq "official" })
$comparisons = if ($SkipOfficial) { @() } else { Compare-Subjects -BuilderSubjects $builderSummaries -OfficialSubjects $officialSummaries }
if (-not $SkipOfficial) {
    Write-FunctionalComparisonLog -BuilderSubjects $builderSummaries -OfficialSubjects $officialSummaries -Comparisons $comparisons
}

$summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    builderRepository = $BuilderRepository
    selectedRuns = $runs
    subjects = $subjectSummaries
    comparisons = $comparisons
}

$summaryJson = Join-Path $ReportDir "qa-summary.json"
$summaryMd = Join-Path $ReportDir "qa-summary.md"
$summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson
Write-MarkdownReport -Summary $summary -Path $summaryMd

$errorCount = 0
$errorCount += @($subjectSummaries | ForEach-Object { $_.issues } | Where-Object { $_.level -eq "error" }).Count
$errorCount += @($comparisons | Where-Object { $_.status -ne "ok" }).Count

Write-Host "QA summary written to $summaryMd"
Get-Content -Path $summaryMd | Write-Host

if ($errorCount -gt 0) {
    throw "Winlibs PHP artifact QA found $errorCount issue(s)"
}
