$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$runtime = Join-Path $env:WINDIR 'SysWOW64\msvcr110.dll'
if (Test-Path $runtime) {
    throw 'VC++ 2012 x86 is already installed; this job would not exercise runtime installation.'
}
$vcZip = Join-Path $env:RUNNER_TEMP 'vcredist.zip'
$vcRoot = Join-Path $env:RUNNER_TEMP 'vcredist'
Invoke-WebRequest -UseBasicParsing "https://github.com/EUCPilots/vcredist/archive/refs/tags/$env:VC_TAG.zip" -OutFile $vcZip
Expand-Archive $vcZip -DestinationPath $vcRoot
$vcManifest = Get-ChildItem $vcRoot -Recurse -Filter VcRedist.psd1 | Select-Object -First 1
Import-Module $vcManifest.FullName -Force
Import-Module "$env:GITHUB_WORKSPACE\phpmanager\PhpManager\PhpManager.psm1" -Force
$manifest = Invoke-RestMethod "https://github.com/shivammathur/php-builder-windows/releases/download/php$env:PHP_VERSION/manifest.json"
$asset = $manifest.stable.php.nts.x86
$url = "https://github.com/shivammathur/php-builder-windows/releases/download/php$env:PHP_VERSION/$asset"
$destination = Join-Path $env:RUNNER_TEMP "PHP $env:PHP_VERSION"
New-Item -ItemType Directory $destination | Out-Null
& (Get-Module PhpManager) {
    param($url, $destination)
    $phpVersion = Get-PhpVersionFromUrl -Url $url -ReleaseState Release
    Install-PhpFromUrl -Url $url -Path $destination -PhpVersion $phpVersion -InstallVCRedist $true -Verbose
} $url $destination
if (!(Test-Path $runtime)) { throw 'VC++ 2012 x86 was not installed.' }
Copy-Item "$destination\php.ini-production" "$destination\php.ini"
Set-PhpIniKey -Path "$destination\php.ini" -Key date.timezone -Value UTC
Set-PhpIniKey -Path "$destination\php.ini" -Key extension_dir -Value "$destination\ext"
$installed = Get-Php -Path $destination
if ($installed.MajorMinorVersion -ne $env:PHP_VERSION -or $installed.Architecture -ne 'x86') {
    throw "Incorrect PHP installed: $($installed.DisplayName)"
}
Enable-PhpExtension -Path $destination -Extension @('openssl', 'curl', 'mbstring', 'opcache')
$versionOutput = & "$destination\php.exe" -v
if ($LASTEXITCODE -ne 0) { throw 'php -v failed.' }
$versionOutput | Write-Host
$modules = & "$destination\php.exe" -m
if ($LASTEXITCODE -ne 0) { throw 'php -m failed.' }
$modules | Write-Host
foreach ($extension in @('openssl', 'curl', 'mbstring', 'Zend OPcache')) {
    if ($modules -notcontains $extension) { throw "Missing extension: $extension" }
}

# Check that the actual downloaded entries survive the elevation handoff.
$list = Get-VcList -Export All | Where-Object { $_.Release -eq '2012' -and $_.Architecture -eq 'x86' }
$downloadDirectory = Join-Path $env:RUNNER_TEMP "VC redistributable's files"
New-Item -ItemType Directory $downloadDirectory | Out-Null
$list | Save-VcRedist -Path $downloadDirectory | Out-Null
$listPath = Join-Path $downloadDirectory 'vcredist.xml'
$list | Export-Clixml -LiteralPath $listPath
$command = "Import-Module '" + ($vcManifest.FullName -replace "'", "''") + "'; Import-Clixml -LiteralPath '" + ($listPath -replace "'", "''") + "' | Install-VcRedist"
if ((Get-Module VcRedist).Version -lt '4.0') {
    $command += " -Path '" + ($downloadDirectory -replace "'", "''") + "'"
}
& powershell.exe -NoProfile -Command "`$ErrorActionPreference = 'Stop'; $command"
if ($LASTEXITCODE -ne 0) { throw 'Serialized runtime handoff failed.' }
$report = [ordered]@{
    commit = $env:PHPMANAGER_SHA
    php = $installed.FullVersion
    architecture = $installed.Architecture
    shell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    vcredist = (Get-Module VcRedist).Version.ToString()
    runtime = (Get-Item $runtime).VersionInfo.FileVersion
    modules = $modules
    serializedHandoff = 'passed'
}
$report | ConvertTo-Json -Depth 4 | Tee-Object -FilePath "$env:RUNNER_TEMP\validation.json"
