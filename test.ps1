$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$artifacts = Join-Path $PSScriptRoot validation
New-Item -Path $artifacts -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $artifacts parent.log) -Force
$moduleRoot = Join-Path $PSScriptRoot phpmanager
$runtime = Join-Path $env:WINDIR 'SysWOW64\msvcr110.dll'
$pins = @{
    'v3.0.333' = '8110f42c8141a31b277d423c659654cd8f21a763'
    'v4.1.527' = '1d4ac92d79084a3b55fe330968baa7b03382f1b3'
    'v5.0.2-beta3' = '84c2c21cb382997c40829b3e6f666f38336218d1'
}
function Get-VcManifest($tag) {
    $directory = Join-Path $env:RUNNER_TEMP $tag
    $archive = "$directory.zip"
    if (!(Test-Path -LiteralPath $directory)) {
        Invoke-WebRequest -UseBasicParsing "https://github.com/EUCPilots/vcredist/archive/$($pins[$tag]).zip" -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $directory
    }
    $manifests = @(Get-ChildItem -LiteralPath $directory -Recurse -Filter VcRedist.psd1)
    if ($manifests.Count -ne 1) { throw "Expected one VcRedist manifest for $tag" }
    return $manifests[0].FullName
}
try {
    $commit = git -C $moduleRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -ne $env:PHPMANAGER_SHA) { throw 'Incorrect PhpManager commit' }
    if (Test-Path -LiteralPath $runtime) { throw 'VC++ 2012 x86 is already present; this job would not prove installation' }
    $parentManifest = Get-VcManifest $env:PARENT_TAG
    $childManifest = Get-VcManifest $env:CHILD_TAG
    Import-Module $parentManifest -Force
    Import-Module (Join-Path $moduleRoot 'PhpManager/PhpManager.psm1') -Force
    $parentCommand = Get-Command Install-VcRedist
    $parentVersion = (Get-Module VcRedist).Version.ToString()
    $phpManifest = Invoke-RestMethod 'https://github.com/shivammathur/php-builder-windows/releases/download/php5.6/manifest.json'
    $url = "https://github.com/shivammathur/php-builder-windows/releases/download/php5.6/$($phpManifest.stable.php.nts.x86)"
    $destination = Join-Path $env:RUNNER_TEMP 'PHP 5.6'
    $childReport = $null
    if ($env:TEST_MODE -eq 'direct') {
        & (Get-Module PhpManager) {
            param ($url, $destination)
            $version = Get-PhpVersionFromUrl -Url $url -ReleaseState Release
            Install-PhpFromUrl -Url $url -Path $destination -PhpVersion $version -InstallVCRedist $true -Verbose
        } $url $destination
    } else {
        $archive = Join-Path $env:RUNNER_TEMP php.zip
        Invoke-WebRequest -UseBasicParsing $url -OutFile $archive
        Expand-ArchiveWith7Zip -ArchivePath $archive -DestinationPath $destination -Overwrite
        $global:LASTEXITCODE = 0
        try { & (Join-Path $destination php.exe) -n -v 2>&1 | Out-String | Write-Host } catch { Write-Host $_ }
        if ($LASTEXITCODE -ne -1073741515) { throw "Expected STATUS_DLL_NOT_FOUND before installation, got $LASTEXITCODE" }
        $vcList = @(Get-VcList -Export All | Where-Object { $_.Release -eq '2012' -and $_.Architecture -eq 'x86' })
        if ($vcList.Count -eq 0) { throw 'VC++ 2012 x86 catalog entry not found' }
        $runtimePath = Join-Path $env:RUNNER_TEMP "VC redistributable's files"
        New-Item -Path $runtimePath -ItemType Directory | Out-Null
        $vcList | Save-VcRedist -Path $runtimePath | Out-Null
        foreach ($entry in $vcList) {
            if (!(Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw 'Downloaded installer is missing' }
        }
        $parameters = @{}
        if ($parentCommand.Parameters.ContainsKey('Path')) { $parameters.Path = $runtimePath }
        # Execute command construction from the exact PR commit, then launch a real Windows PowerShell child.
        $startProcess = (Get-Command Install-PhpFromUrl).ScriptBlock.Ast.Find({
            param ($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
        }, $true)
        $block = $startProcess.Parent.Parent
        if ($block -ne $block.Parent.ElseClause) { throw 'Expected the non-administrator block' }
        $construction = $block.Statements | Where-Object { $_.Extent.StartOffset -ne $startProcess.Parent.Extent.StartOffset }
        $script = [scriptblock]::Create(($construction.Extent.Text -join "`n") + "`nreturn `$exeCommand")
        $command = & (Get-Module PhpManager) {
            param ($script, $temporaryDirectory2, $vcList, $vcRedistParameters)
            & $script
        } $script $runtimePath $vcList $parameters
        Set-Content -LiteralPath (Join-Path $artifacts generated-command.txt) -Value $command -Encoding UTF8
        $listPath = Join-Path $runtimePath vcredist.xml
        Copy-Item -LiteralPath $listPath -Destination (Join-Path $artifacts vcredist.xml)
        $childConfiguration = @{
            manifest = $childManifest
            catalog = $listPath
            command = $command
            runtime = $runtime
            report = (Join-Path $artifacts child.json)
            transcript = (Join-Path $artifacts child.log)
            expectedVersion = (Import-PowerShellDataFile -LiteralPath $childManifest).ModuleVersion.ToString()
            parentPid = $PID
        }
        $configurationPath = Join-Path $env:RUNNER_TEMP child.xml
        $childConfiguration | Export-Clixml -LiteralPath $configurationPath
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot child.ps1) -Configuration $configurationPath
        if ($LASTEXITCODE -ne 0) { throw "Real Windows PowerShell child failed with exit code $LASTEXITCODE" }
        $childReport = Get-Content -LiteralPath $childConfiguration.report -Raw | ConvertFrom-Json
        if ($childReport.pid -eq $PID -or !$childReport.runtimeInstalled) { throw 'Child installation was not proven' }
    }
    if (!(Test-Path -LiteralPath $runtime)) { throw 'VC++ 2012 x86 was not installed' }
    Copy-Item (Join-Path $destination php.ini-production) (Join-Path $destination php.ini)
    Set-PhpIniKey -Path (Join-Path $destination php.ini) -Key date.timezone -Value UTC
    Set-PhpIniKey -Path (Join-Path $destination php.ini) -Key extension_dir -Value (Join-Path $destination ext)
    $installed = Get-Php -Path $destination
    if ($installed.MajorMinorVersion -ne '5.6' -or $installed.Architecture -ne 'x86') { throw 'Unexpected PHP version or architecture' }
    Enable-PhpExtension -Path $destination -Extension @('openssl', 'curl', 'mbstring', 'opcache')
    & (Join-Path $destination php.exe) -v
    if ($LASTEXITCODE -ne 0) { throw 'php -v failed after runtime installation' }
    $modules = & (Join-Path $destination php.exe) -m
    if ($LASTEXITCODE -ne 0) { throw 'php -m failed after runtime installation' }
    foreach ($extension in @('openssl', 'curl', 'mbstring', 'Zend OPcache')) {
        if ($modules -notcontains $extension) { throw "Missing extension: $extension" }
    }
    [ordered]@{
        commit = $commit
        installerSha256 = (Get-FileHash (Join-Path $moduleRoot 'PhpManager/private/Install-PhpFromUrl.ps1')).Hash
        mode = $env:TEST_MODE
        shell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
        parentTag = $env:PARENT_TAG
        parentCommit = $pins[$env:PARENT_TAG]
        parentVersion = $parentVersion
        parentPathParameter = $parentCommand.Parameters.ContainsKey('Path')
        parentCatalogParameterType = $parentCommand.Parameters['VcList'].ParameterType.FullName
        childTag = $env:CHILD_TAG
        childCommit = $pins[$env:CHILD_TAG]
        child = $childReport
        runtimeInitiallyAbsent = $true
        runtime = (Get-Item $runtime).VersionInfo.FileVersion
        php = $installed.FullVersion
        architecture = $installed.Architecture
        modules = $modules
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $artifacts validation.json) -Encoding UTF8
} finally {
    Stop-Transcript
}
