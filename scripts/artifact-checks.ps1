Set-StrictMode -Version Latest
function Assert-Equal($Expected, $Actual, [string] $Label) {
  if ($Expected -cne $Actual) { throw "$Label expected '$Expected', got '$Actual'" }
}
function Get-Variant([string] $Name) {
  if ($Name -notmatch '^php-(?<version>\d+\.\d+\.\d+-dev)-(?<nts>nts-)?Win32-(?<vs>vs\d+)-(?<arch>x64|x86)\.zip$') { throw "Unexpected runtime ZIP: $Name" }
  [pscustomobject]@{ Version=$Matches.version; Compiler=$Matches.vs; Arch=$Matches.arch; Zts= -not [bool]$Matches['nts'] }
}
function Assert-Hash([string] $Path, [string] $Expected) {
  Assert-Equal $Expected.ToLowerInvariant() (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() "SHA256 $Path"
}
function Assert-Pe([string] $Path, [string] $Arch) {
  $bytes=[IO.File]::ReadAllBytes($Path)
  Assert-Equal 0x5a4d ([int][BitConverter]::ToUInt16($bytes,0)) "DOS signature $Path"
  $offset=[BitConverter]::ToInt32($bytes,60)
  Assert-Equal 0x4550 ([int][BitConverter]::ToUInt32($bytes,$offset)) "PE signature $Path"
  $expected=if($Arch -eq 'x64'){0x8664}else{0x14c}
  Assert-Equal $expected ([int][BitConverter]::ToUInt16($bytes,$offset+4)) "PE architecture $Path"
}
function Assert-Report($Report, $Variant, [int] $Opcache) {
  Assert-Equal 0 $Report.failures 'suite failures'
  Assert-Equal $Variant.Version $Report.php 'PHP artifact version'
  Assert-Equal 'Windows' $Report.os 'OS'
  Assert-Equal $(if($Variant.Arch -eq 'x64'){64}else{32}) $Report.bits 'PHP bitness'
  Assert-Equal ([bool]$Variant.Zts) ([bool]$Report.zts) 'thread safety'
  Assert-Equal "$Opcache" $Report.opcache 'OPcache mode'
  Assert-Equal '3.54.1' $Report.sqlite.versionString 'SQLite version'
  if ($Report.tests -lt 300 -or $Report.assertions -lt 1200) { throw 'Incomplete suite: test/assertion floor not reached' }
  Assert-Equal $Report.tests @($Report.results).Count 'report test count'
  Assert-Equal $Report.assertions ($Report.results | Measure-Object -Property assertions -Sum).Sum 'report assertion count'
  Assert-Equal 0 @($Report.results | Where-Object assertions -lt 1).Count 'cases without assertions'
  Assert-Equal 0 @($Report.results | Where-Object status -ne 'pass').Count 'nonpassing results'
  foreach($driver in @('sqlite3','pdo') + $(if($Variant.Version -match '^8\.[4-7]\.'){@('pdo-class')}else{@()})) {
    foreach($gate in @('sql-functions','virtual-table-modules')) {
      Assert-Equal 1 @($Report.results | Where-Object { $_.name -eq "$driver/coverage/$gate" -and $_.status -eq 'pass' }).Count "coverage gate $driver/$gate"
    }
  }
  Assert-Equal 1 @($Report.results | Where-Object { $_.name -eq 'coverage/public-api-inventory' -and $_.status -eq 'pass' }).Count 'API coverage gate'
}
