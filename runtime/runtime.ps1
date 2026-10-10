param([string]$Repository, [string]$Scenario)
$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item $work -ItemType Directory | Out-Null
try {
  . "$Repository/src/scripts/tools/add_tools.ps1"
  $composer_bin = "$work/bin"
  $composer_lock = "$work/composer.lock"
  $composer_version = '2.9.0'
  $php_dir = $work
  $env:fail_fast = 'true'
  $tick = 'ok'
  $cross = 'error'
  function Enable-PhpExtension { }
  function Add-Path { param($path); Write-Host "PATH $path" }
  function Add-ToolsHelper { }
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile("$Repository/src/scripts/win32.ps1", [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
  $logger = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-Log' }, $true)
  . ([scriptblock]::Create($logger.Extent.Text))
  if ($IsWindows) { $env:PATH += ';C:\Program Files\Git\usr\bin' }
  function Add-Tool {
    param($url, $tool, $versionParameter)
    Write-Host "FALLBACK $url $tool $versionParameter"
    if ($Scenario -eq 'both-fail') { throw 'PHAR failed' }
  }
  function findstr { param($pattern); process { if ($_ -match $pattern) { $_ } } }
  function composer {
    $arguments = @($args)
    if ($arguments[0] -eq 'global') { $arguments = $arguments[1..($arguments.Length-1)] }
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'require') {
      Add-Content "$work/attempts" 'require'
      if ($Scenario -in @('success','retry','no-show')) {
        New-Item "$scoped_dir/vendor" -ItemType Directory -Force | Out-Null
        Set-Content "$scoped_dir/vendor/autoload.php" ''
      } else { $global:LASTEXITCODE = 1 }
    } elseif ($arguments[0] -eq 'show') {
      if ($arguments -contains '-a') { return }
      if ($Scenario -eq 'no-show') { $global:LASTEXITCODE = 1; return }
      'versions : * 2.3.0'
    }
  }
  $release = 'phpstan'
  $suffix = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($release)))
  $scoped_dir = "$composer_bin/_tools/phpstan-$suffix"
  if ($Scenario -eq 'cached') {
    New-Item "$scoped_dir/vendor" -ItemType Directory -Force | Out-Null
    Set-Content "$scoped_dir/vendor/autoload.php" ''
  } elseif ($Scenario -eq 'retry') { New-Item $scoped_dir -ItemType Directory -Force | Out-Null }
  $fallback = if ($Scenario -eq 'no-fallback') { '' } else { 'https://example.com/phpstan.phar' }
  $scope = if ($Scenario -eq 'global-failure') { 'global' } else { 'scoped' }
  Add-ComposerTool phpstan $release phpstan/ $scope $fallback '-V'
  if ($Scenario -eq 'cached' -and (Test-Path "$work/attempts")) { throw 'Reinstalled healthy cache' }
  if ($Scenario -eq 'retry' -and @(Get-Content "$work/attempts").Count -ne 1) { throw 'Did not retry incomplete install' }
} finally { Remove-Item $work -Recurse -Force }
