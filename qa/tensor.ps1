$ErrorActionPreference = 'Stop'
New-Item validation -ItemType Directory -Force | Out-Null
$archive = Get-ChildItem artifacts -Filter 'php_tensor-*.zip' | Select-Object -First 1
if (-not $archive) { throw 'Tensor artifact missing' }
Expand-Archive $archive.FullName validation/tensor
$php = Get-ChildItem C:/build -Filter php.exe -Recurse | Where-Object { $_.Directory.Name -eq 'php-bin' } | Select-Object -First 1
if (-not $php) { throw 'Test PHP executable missing' }
$dll = Get-Item validation/tensor/php_tensor.dll
$packaged = Get-FileHash validation/tensor/libopenblas.dll
$expected = Get-FileHash C:/build/deps/bin/libopenblas.dll
if ($packaged.Hash -ne $expected.Hash) { throw 'Tensor was packaged with the wrong OpenBLAS DLL' }
foreach ($license in Get-ChildItem C:/build/deps/share/licenses -Filter 'LICENSE.OpenBLAS*' -Recurse -File) {
    $copy = Join-Path validation/tensor $license.Name
    if ((Get-FileHash $copy).Hash -ne (Get-FileHash $license.FullName).Hash) { throw "Tensor lost or changed $($license.Name)" }
}
Copy-Item C:/build/deps/bin/libopenblas.dll $php.Directory.FullName -Force
Invoke-WebRequest https://phar.phpunit.de/phpunit-9.phar -OutFile validation/phpunit.phar
$arguments = @('-n', '-d', "extension_dir=$($php.Directory.FullName)/ext", '-d', 'extension=mbstring', '-d', "extension=$($dll.FullName)")
& $php.FullName @arguments --ri tensor | Tee-Object validation/tensor-info.txt
if ($LASTEXITCODE) { throw 'Tensor failed to load' }
& $php.FullName @arguments validation/phpunit.phar --no-configuration --bootstrap qa/bootstrap.php --log-junit validation/tensor.xml tensor-tests/tests 2>&1 | Tee-Object validation/tensor-tests.txt
if ($LASTEXITCODE) { throw 'Upstream Tensor tests failed' }
