New-Item -ItemType Directory -Force .validation/results/failures | Out-Null
$roots = @('Zend', 'ext', 'sapi', 'tests', 'C:/tests_tmp')
foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Recurse -File -Include *.diff,*.out,*.exp,*.log | ForEach-Object {
        $relative = if ($_.FullName.StartsWith($PWD.Path)) { $_.FullName.Substring($PWD.Path.Length + 1) } else { 'temp/' + $_.FullName.Substring('C:\tests_tmp\'.Length) }
        $destination = Join-Path .validation/results/failures $relative
        New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
        Copy-Item $_.FullName $destination
    }
}
git diff --stat | Set-Content .validation/results/source-diff-stat.txt
if (Test-Path .validation/null-probe.exe) { Copy-Item .validation/null-probe.exe .validation/results/ }
