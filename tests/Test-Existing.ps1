$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-Module -ListAvailable Pester | Where-Object Version -EQ '4.10.1')) {
    if ($PSVersionTable.PSVersion.Major -eq 5) { Get-PackageProvider -Name NuGet -ForceBootstrap | Out-Null }
    Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
}
Import-Module Pester -RequiredVersion 4.10.1 -Force
$results = foreach ($tree in 'base','builder') {
    $result = Invoke-Pester -Script (Join-Path $root "$tree/php/BuildPhp/tests") -Show Summary,Failed -PassThru -OutputFile (Join-Path $root "results/pester-$tree.xml") -OutputFormat NUnitXml
    $failures = @($result.TestResult | Where-Object { -not $_.Passed } | Select-Object -ExpandProperty Name)
    $expected = @('Compare the count of Function Exported and the PS1 files found','Compare the missing function')
    if ($result.PassedCount -ne 23 -or $result.FailedCount -ne 2 -or (Compare-Object $expected $failures)) { throw "Unexpected existing test result for $tree" }
    [pscustomobject]@{ tree=$tree; passed=$result.PassedCount; failed=$result.FailedCount; expectedFailures=$failures }
}
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'results/existing-results.json') -Encoding UTF8
