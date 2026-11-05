const fs = require('node:fs');
const root = 'setup-php/src/scripts/';
function edit(file, from, to) {
  const p = root + file;
  const original = fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
  if (!original.includes(from)) throw new Error('Missing profile anchor: ' + file + ': ' + from);
  fs.writeFileSync(p, original.replace(from, to));
}
edit('tools/add_tools.ps1', '$phpstan_version = Get-ToolVersion phpstan', 'Write-Host "PROFILE phpstan.downloaded $(Get-Date -Format o)"\n    $phpstan_version = Get-ToolVersion phpstan');
edit('tools/add_tools.ps1', 'Add-PieExtension phpstan_turbo "phpstan/turbo:$phpstan_version"', 'Write-Host "PROFILE phpstan.versioned $(Get-Date -Format o)"\n    Add-PieExtension phpstan_turbo "phpstan/turbo:$phpstan_version"');
edit('extensions/add_extensions.ps1', "  $pie_path = Join-Path $bin_dir 'pie'", "  Write-Host \"PROFILE pie.bootstrap.start $(Get-Date -Format o)\"\n  $pie_path = Join-Path $bin_dir 'pie'");
edit('extensions/add_extensions.ps1', "  $pie_args = @('install'", "  Write-Host \"PROFILE pie.bootstrap.end $(Get-Date -Format o)\"\n  & php -d phar.readonly=0 \"$env:GITHUB_WORKSPACE/fixtures/instrument-pie.php\" $pie_path\n  $pie_args = @('install'");
edit('extensions/add_extensions.ps1', '  & pie @pie_args >$null 2>&1', '  Write-Host "PROFILE pie.install.start $(Get-Date -Format o)"\n  & php $env:PIE_PROFILE_PHAR @pie_args -vvv 2>&1 | Out-Host\n  Write-Host "PROFILE pie.install.end $(Get-Date -Format o)"');
edit('extensions/add_extensions.ps1', '  Enable-ExtensionDependencies $extension\n  Enable-PhpExtension -Extension $extension -Path $php_dir\n  $extension_info = Get-PhpExtension', '  Write-Host "PROFILE enable.start $(Get-Date -Format o)"\n  Enable-ExtensionDependencies $extension\n  Enable-PhpExtension -Extension $extension -Path $php_dir\n  Write-Host "PROFILE enable.end $(Get-Date -Format o)"\n  $extension_info = Get-PhpExtension');
edit('extensions/add_extensions.ps1', '  if ($null -eq $extension_info) {', '  Write-Host "PROFILE loaded-check.end $(Get-Date -Format o)"\n  if ($null -eq $extension_info) {');
edit('tools/add_tools.sh', '    if (pie_install phpstan_turbo', '    printf "PROFILE phpstan.downloaded\\n"\n    if (pie_install phpstan_turbo');
edit('extensions/add_extensions.sh', '  if ! command -v pie >/dev/null 2>&1; then', '  printf "PROFILE pie.bootstrap.start\\n"\n  if ! command -v pie >/dev/null 2>&1; then');
edit('extensions/add_extensions.sh', '  if php_config=$(command -v php-config); then', '  printf "PROFILE pie.bootstrap.end\\n"\n  php -d phar.readonly=0 "$GITHUB_WORKSPACE/fixtures/instrument-pie.php" "$(command -v pie)"\n  if php_config=$(command -v php-config); then');
edit('extensions/add_extensions.sh', '  sudo -E "$(command -v pie)" "${pie_args[@]}" >/dev/null 2>&1 || return $?', '  printf "PROFILE pie.install.start\\n"\n  sudo -E "$PIE_PROFILE_PHAR" "${pie_args[@]}" -vvv || return $?\n  printf "PROFILE pie.install.end\\n"');
edit('extensions/add_extensions.sh', '  enable_extension "$extension" "$prefix"\n  check_extension "$extension"', '  printf "PROFILE enable.start\\n"\n  enable_extension "$extension" "$prefix"\n  printf "PROFILE enable.end\\n"\n  check_extension "$extension"\n  printf "PROFILE loaded-check.end\\n"');
for (const file of ['extensions/add_extensions.sh', 'extensions/add_extensions.ps1']) {
  edit(file, 'https://github.com/php/pie/releases/latest/download/pie.phar', `https://github.com/php/pie/releases/download/${process.env.PIE_VERSION}/pie.phar`);
}
