$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'results'
$builder = Join-Path $root 'builder'
$fixture = Join-Path $root 'fixtures'
$originalProgramFiles = ${env:ProgramFiles(x86)}
$originalTemp = $env:TEMP
$vswhere = Join-Path $originalProgramFiles 'Microsoft Visual Studio/Installer/vswhere.exe'
if ($PSVersionTable.PSVersion.Major -ne [int]$env:EXPECTED_PS_MAJOR) { throw 'Unexpected PowerShell version' }
$script:checks = 0
function Assert-Equal($actual, $expected, $label) {
    if ($actual -cne $expected) { throw "$label expected [$expected], got [$actual]" }
    $script:checks++
}
$nativeInstances = @(& $vswhere -products '*' -format json | ConvertFrom-Json | ForEach-Object { $_ })
if (-not $nativeInstances.Count) { throw 'Runner has no real Visual Studio installation' }
$nativeInstances | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $out 'installed-vs.json') -Encoding UTF8
$nativeResults = @()
foreach ($relative in 'php/BuildPhp','extension/BuildPhpExtension') {
    $moduleDir = Join-Path $builder $relative
    $name = Split-Path $moduleDir -Leaf
    $manifest = Join-Path $moduleDir "$name.psd1"
    Test-ModuleManifest $manifest | Out-Null
    Import-Module $manifest -Force -DisableNameChecking
    $ids = @(& "$name\Get-VsProductIds")
    Assert-Equal $ids.Count 4 "$name exported product IDs"
    Assert-Equal @($ids | Select-Object -Unique).Count 4 "$name unique product IDs"
    $config = Get-Content (Join-Path $moduleDir 'config/vs.json') -Raw | ConvertFrom-Json
    $toolset = & "$name\Get-VsVersionHelper" -VsVersion $env:EXPECTED_VS -VsConfig $config
    if ($toolset -notmatch '^14\.') { throw "Invalid installed toolset: $toolset" }
    $nativeResults += @{ module=$name; toolset=$toolset; vs=$env:EXPECTED_VS }
    if ($name -eq 'BuildPhpExtension') {
        $expectedPath = & $vswhere -latest -products $ids -property installationPath
        Assert-Equal (BuildPhpExtension\Get-VsInstallPath) $expectedPath 'Real VS installation path'
    } else {
        foreach ($arch in 'x86','x64') {
            $testRoot = Join-Path $out "helpers-$arch"
            $helperDir = Join-Path $testRoot 'ext/standard/tests/helpers'
            New-Item -ItemType Directory -Path $helperDir -Force | Out-Null
            Copy-Item (Join-Path $root 'php-master/ext/standard/tests/helpers/bad_cmd.c') $helperDir
            BuildPhp\Add-WindowsTestHelpers -TestsDirectoryPath $testRoot -Arch $arch
            $exe = Join-Path $helperDir 'bad_cmd.exe'
            $bytes = [IO.File]::ReadAllBytes($exe)
            $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
            Assert-Equal ([Text.Encoding]::ASCII.GetString($bytes, $peOffset, 4)) "PE`0`0" "$arch PE signature"
            $expectedMachine = if ($arch -eq 'x86') { 0x14c } else { 0x8664 }
            Assert-Equal ([BitConverter]::ToUInt16($bytes, $peOffset + 4)) $expectedMachine "$arch PE machine"
            $output = & $exe
            Assert-Equal $LASTEXITCODE 0 "$arch compiled executable exit code"
            Assert-Equal $output 'pwnd!' "$arch compiled executable output"
            $hash = (Get-FileHash $exe).Hash
            BuildPhp\Add-WindowsTestHelpers -TestsDirectoryPath $testRoot -Arch $arch
            Assert-Equal (Get-FileHash $exe).Hash $hash "$arch helper reuse"
        }
    }
    Remove-Module $name
}
$nativeResults | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'native-toolsets.json') -Encoding UTF8

# An actual .NET executable records native argv and supplies controlled VS/SSMS inventories.
${env:ProgramFiles(x86)} = Join-Path $fixture 'Program Files (x86)'
$installerDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer'
New-Item -ItemType Directory -Path $installerDir -Force | Out-Null
Copy-Item (Join-Path $fixture 'native-fixture.exe') (Join-Path $installerDir 'vswhere.exe')
$env:TEMP = Join-Path $fixture 'downloads'
New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
$env:PR37_ARGS = Join-Path $out 'vswhere-argv.jsonl'
$env:PR37_INSTANCES = Join-Path $fixture 'instances.json'
$env:PR37_INSTALL_ARGS = Join-Path $out 'installer-argv.json'
$baselineFailures = @()
$fixtureResults = @()
try {
    foreach ($relative in 'php/BuildPhp','extension/BuildPhpExtension') {
        $moduleDir = Join-Path $builder $relative
        $name = Split-Path $moduleDir -Leaf
        foreach ($functionName in 'Get-VsProductIds','Get-VsVersionHelper','Add-VS') { . (Join-Path $moduleDir "private/$functionName.ps1") }
        if ($name -eq 'BuildPhpExtension') { . (Join-Path $moduleDir 'private/Get-VsInstallPath.ps1') }
        function Add-StepLog {}
        function Set-GAGroup {}
        function Add-BuildLog {}
        function Get-File {
            param($Url, $OutFile)
            $script:downloadUrl = $Url
            Copy-Item (Join-Path $fixture 'native-fixture.exe') $OutFile -Force
        }
        $config = Get-Content (Join-Path $moduleDir 'config/vs.json') -Raw | ConvertFrom-Json
        $ssms = [pscustomobject]@{ productId='Microsoft.VisualStudio.Product.SSMS'; catalog=$null; installationVersion='22.0.0'; installationPath=(Join-Path $fixture 'SSMS 22') }
        $old = [pscustomobject]@{ productId='Microsoft.VisualStudio.Product.Community'; catalog=$null; installationVersion='17.14.0'; installationPath=(Join-Path $fixture 'VS 2022') }
        New-Item -ItemType Directory -Force (Join-Path $old.installationPath 'VC/Tools/MSVC/14.44.35207') | Out-Null
        foreach ($edition in 'Enterprise','Professional','Community','BuildTools') {
            $productId = "Microsoft.VisualStudio.Product.$edition"
            $catalog = if ($edition -in 'Enterprise','Community') { @{ productId=$productId } } else { $null }
            $vs = [pscustomobject]@{ productId=$productId; catalog=$catalog; installationVersion='18.1.0'; installationPath=(Join-Path $fixture "VS 2026 $edition") }
            New-Item -ItemType Directory -Force (Join-Path $vs.installationPath 'VC/Tools/MSVC/14.52.37025') | Out-Null
            ConvertTo-Json -InputObject @($ssms,$vs,$old) -Depth 10 | Set-Content $env:PR37_INSTANCES -Encoding UTF8
            Assert-Equal (Get-VsVersionHelper -VsVersion vs18 -VsConfig $config) '14.52.37025' "$name mixed VS18 toolset"
            Assert-Equal (Get-VsVersionHelper -VsVersion vs17 -VsConfig $config) '14.44.35207' "$name mixed VS17 toolset"
            if ($name -eq 'BuildPhpExtension') { Assert-Equal (Get-VsInstallPath) $vs.installationPath 'Mixed install path excludes SSMS' }
            Add-VS -VsVersion vs18 -VsConfig $config
            $exe = if ($edition -eq 'BuildTools') { 'vs_buildtools.exe' } else { "vs_$($edition.ToLower()).exe" }
            Assert-Equal $script:downloadUrl "https://aka.ms/vs/18/stable/$exe" "$name selected installer URL"
            $installArgs = Get-Content $env:PR37_INSTALL_ARGS -Raw | ConvertFrom-Json
            Assert-Equal $installArgs[0] 'modify' 'Installer modify mode'
            Assert-Equal $installArgs[2] $vs.installationPath 'Installer target path'
            $fixtureResults += @{ module=$name; scenario=$edition; result='pass' }
        }
        if ($PSVersionTable.PSVersion.Major -eq 5) {
            . (Join-Path $root "base/$relative/private/Get-VsVersionHelper.ps1")
            $failure = $null
            try { Get-VsVersionHelper -VsVersion vs18 -VsConfig $config | Out-Null } catch { $failure=$_.Exception.Message }
            if (-not $failure) { throw 'Baseline multi-instance regression was not reproduced' }
            $baselineFailures += @{ module=$name; error=$failure }
            . (Join-Path $moduleDir 'private/Get-VsVersionHelper.ps1')
        }
        $scenarios = @(
            @{ Name='empty'; Instances=@() },
            @{ Name='SSMS only'; Instances=@($ssms) },
            @{ Name='older VS'; Instances=@($old) }
        )
        foreach ($scenario in $scenarios) {
            ConvertTo-Json -InputObject $scenario.Instances -Depth 10 | Set-Content $env:PR37_INSTANCES -Encoding UTF8
            $failure = $null
            try { Get-VsVersionHelper -VsVersion vs18 -VsConfig $config | Out-Null } catch { $failure=$_.Exception.Message }
            Assert-Equal $failure 'toolset not available' 'Missing VS18 toolset'
            Add-VS -VsVersion vs18 -VsConfig $config
            Assert-Equal $script:downloadUrl 'https://aka.ms/vs/18/stable/vs_buildtools.exe' 'Fallback installer URL'
            $installArgs = Get-Content $env:PR37_INSTALL_ARGS -Raw | ConvertFrom-Json
            Assert-Equal $installArgs[0] '--quiet' 'Fresh install mode'
            if ($name -eq 'BuildPhpExtension' -and $scenario.Name -ne 'older VS') { Assert-Equal (Get-VsInstallPath) '' 'Absent VS path' }
            $fixtureResults += @{ module=$name; scenario=$scenario.Name; result='pass' }
        }
    }
    $ids = @(Get-VsProductIds)
    foreach ($line in Get-Content $env:PR37_ARGS) {
        $argv = $line | ConvertFrom-Json
        if ($argv -contains '-latest') { Assert-Equal ($argv[2..5] -join ',') ($ids -join ',') 'Separate product IDs in native argv' }
    }
} finally {
    ${env:ProgramFiles(x86)} = $originalProgramFiles
    $env:TEMP = $originalTemp
}
[ordered]@{ powershell=$PSVersionTable.PSVersion.ToString(); checks=$script:checks; native=$nativeResults; fixtures=$fixtureResults; baselineFailures=$baselineFailures } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $out 'vs-results.json') -Encoding UTF8
Write-Host "VS assertions passed: $script:checks; baseline failures reproduced: $($baselineFailures.Count)"
