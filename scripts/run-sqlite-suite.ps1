param([Parameter(Mandatory)][string]$Target)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot/artifact-checks.ps1"
$root=Split-Path $PSScriptRoot
$manifest=Get-Content "$root/artifacts.json" -Raw | ConvertFrom-Json
$build=@($manifest.builds | Where-Object ref -eq $Target)
Assert-Equal 1 $build.Count 'manifest build selection'
$build=$build[0]
$reports=New-Item -ItemType Directory -Force "$root/reports"
$headers=@{Authorization="Bearer $env:GH_TOKEN";Accept='application/vnd.github+json'}
$run=Invoke-RestMethod "https://api.github.com/repos/$($manifest.repository)/actions/runs/$($build.run)" -Headers $headers
$run | ConvertTo-Json -Depth 20 | Set-Content "$reports/source-run.json"
Assert-Equal 'success' $run.conclusion 'source build conclusion'
Assert-Equal $build.builder_sha $run.head_sha 'source builder SHA'
Assert-Equal '.github/workflows/test-php-libs-from-source.yml' $run.path 'source workflow'
$zips=@(Get-ChildItem "$root/artifacts" -Recurse -File -Filter '*.zip' | Where-Object { $_.Name -match '^php-\d.*Win32-vs\d+-(x64|x86)\.zip$' })
Assert-Equal 4 $zips.Count 'runtime ZIP count'
Assert-Equal 4 @($build.packages).Count 'manifest package count'
$seen=@{}
foreach($package in $build.packages){
  $zip=@($zips | Where-Object Name -eq $package.name);Assert-Equal 1 $zip.Count "package $($package.name)";Assert-Hash $zip[0].FullName $package.sha256
  $v=Get-Variant $package.name;$key="$($v.Arch)-$($v.Zts)";if($seen.ContainsKey($key)){throw "Duplicate variant $key"};$seen[$key]=$true
}
$work=Join-Path $env:RUNNER_TEMP ('sqlite-qa-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if($LASTEXITCODE -ne 0 -or !$vs){throw 'MSVC compiler not found'}
$vcvars=Join-Path $vs 'VC/Auxiliary/Build/vcvarsall.bat'
foreach($arch in 'x64','x86'){
  $out=New-Item -ItemType Directory -Path "$work/extension-$arch"
  $source="$root/tests/sqlite/extension/qaextension.c"
  $batch="$out/compile.cmd"
  @("@echo off", "call `"$vcvars`" $arch >nul",'if errorlevel 1 exit /b 1',"cl /nologo /LD /O2 /W4 /WX /MD `"$source`" /Fo`"$out/qaextension.obj`" /link /OUT:`"$out/qaextension.dll`"",'exit /b %errorlevel%') | Set-Content $batch -Encoding ascii
  & cmd.exe /d /c $batch 2>&1 | Tee-Object "$reports/compile-$arch.log"
  if($LASTEXITCODE -ne 0){throw "Fixture compilation failed: $arch"};Assert-Pe "$out/qaextension.dll" $arch
}
function Invoke-Php([string]$Php,[string[]]$Arguments,[string]$Log,[int]$Timeout=120000){
  $start=[Diagnostics.ProcessStartInfo]::new($Php);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($arg in $Arguments){$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  if(!$process.WaitForExit($Timeout)){$process.Kill($true);$process.WaitForExit();[IO.File]::WriteAllText($Log,$stdout.Result+$stderr.Result);throw 'PHP process exceeded timeout'}
  $text=$stdout.Result+$stderr.Result;[IO.File]::WriteAllText($Log,$text);$code=$process.ExitCode;$process.Dispose()
  $text -split "`n" | Where-Object {$_ -match '^(FAIL|TOTAL|Fatal|Warning|Parse)'} | Write-Host
  if($code -ne 0){throw "PHP exited $code; see $Log"}
  if($text -match '(?im)^(PHP )?(Warning|Fatal error|Parse error):'){throw "PHP startup/runtime diagnostic; see $Log"}
}
$failures=[Collections.Generic.List[string]]::new();$summaries=[Collections.Generic.List[object]]::new()
$oldPath=$env:PATH
foreach($package in $build.packages){
  $v=Get-Variant $package.name;$id=$package.name -replace '\.zip$','';$dest="$work/$id"
  $packageReports=New-Item -ItemType Directory -Path "$reports/$id"
  try{
    Expand-Archive -LiteralPath ($zips | Where-Object Name -eq $package.name).FullName -DestinationPath $dest
    foreach($file in $package.files.psobject.Properties){Assert-Hash "$dest/$($file.Name)" $file.Value;Assert-Pe "$dest/$($file.Name)" $v.Arch}
    $sbom=Get-Content "$dest/extras/sbom/php.cdx.json" -Raw | ConvertFrom-Json
    $sqlite=@($sbom.components | Where-Object name -eq 'sqlite3');Assert-Equal 1 $sqlite.Count 'SBOM SQLite component';Assert-Equal '3.54.1' $sqlite[0].version 'SBOM SQLite version'
    $properties=@{};foreach($property in $sqlite[0].properties){$properties[$property.name]=$property.value}
    Assert-Equal '9652784a43e2719e1ab71f3276b87e5be8a66696' $properties['php:source-commit'] 'SQLite source commit'
    Assert-Equal $v.Compiler $properties['php:vs'] 'SQLite compiler lane'
    Assert-Equal $v.Arch $properties['php:arch'] 'SQLite SBOM architecture'
    $package | ConvertTo-Json -Depth 10 | Set-Content "$packageReports/artifact.json"
    $env:PATH="$dest;$env:SystemRoot\System32;$env:SystemRoot"
    $scan=New-Item -ItemType Directory -Path "$dest/empty-ini-scan";$env:PHP_INI_SCAN_DIR=$scan.FullName
    $fixtureDir=(Resolve-Path "$work/extension-$($v.Arch)").Path
    $env:SQLITE_QA_EXTENSION=Join-Path $fixtureDir 'qaextension.dll';$env:SQLITE_QA_LIBRARY="$dest/libsqlite3.dll"
    foreach($opcache in 0,1){
      $report=New-Item -ItemType Directory -Path "$packageReports/opcache-$opcache"
      try{
        $ini="$report/php.ini"
        $opcacheConfig=if([version]($v.Version -replace '-dev$','') -lt [version]'8.5.0'){
          $dll=Join-Path $dest 'ext/php_opcache.dll';if(!(Test-Path $dll)){throw 'Required OPcache DLL missing for PHP < 8.5'}
          'zend_extension="'+$dll+'"'
        }else{
          if(Test-Path (Join-Path $dest 'ext/php_opcache.dll')){throw 'Unexpected OPcache DLL for PHP >= 8.5'}
          '; OPcache is statically linked in PHP >= 8.5'
        }
        @('[PHP]',"extension_dir=`"$dest/ext`"",'extension=sqlite3','extension=pdo_sqlite',$opcacheConfig,"opcache.enable_cli=$opcache",'opcache.jit=disable','opcache.file_update_protection=0','date.timezone=UTC','error_reporting=-1','display_errors=1','display_startup_errors=1','log_errors=0','memory_limit=256M',"sqlite3.extension_dir=`"$fixtureDir`"") | Set-Content $ini -Encoding ascii
        Invoke-Php "$dest/php.exe" @('-c',$ini,'-v') "$report/php-version.log"
        Invoke-Php "$dest/php.exe" @('-c',$ini,'-m') "$report/php-modules.log"
        Invoke-Php "$dest/php.exe" @('-c',$ini,"$root/tests/sqlite/harness-selftest.php","$dest/selftest-$opcache") "$report/harness-selftest.log"
        Invoke-Php "$dest/php.exe" @('-c',$ini,"$root/tests/sqlite/run.php","--work=$dest/work-$opcache","--report=$report") "$report/suite.log"
        $result=Get-Content "$report/results.json" -Raw | ConvertFrom-Json
        Assert-Report $result $v $opcache
        $xml=[xml](Get-Content "$report/junit.xml" -Raw);Assert-Equal "$($result.tests)" $xml.testsuite.tests 'JUnit test count';Assert-Equal '0' $xml.testsuite.failures 'JUnit failures'
        $summaries.Add([pscustomobject]@{package=$package.name;opcache=$opcache;tests=$result.tests;assertions=$result.assertions;failures=0})
      }catch{$failures.Add("$id/opcache-$opcache : $_");$_ | Out-String | Set-Content "$report/runner-error.txt";Write-Host "::error::$id/opcache-$opcache failed: $_"}
    }
  }catch{$failures.Add("$id : $_");$_ | Out-String | Set-Content "$packageReports/runner-error.txt";Write-Host "::error::$id failed: $_"}
  finally{$env:PATH=$oldPath}
}
$summaries | ConvertTo-Json -Depth 5 | Set-Content "$reports/summary.json"
$failures | ConvertTo-Json | Set-Content "$reports/failures.json"
"## $Target SQLite userland QA`n" | Add-Content $env:GITHUB_STEP_SUMMARY
$summaries | Format-Table | Out-String | Add-Content $env:GITHUB_STEP_SUMMARY
Assert-Equal 0 $failures.Count ($failures -join "`n")
Assert-Equal 8 $summaries.Count 'four PHP variants times two OPcache modes'
