const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2] || 'setup-php';
function edit(file, apply) {
  const target = path.join(root, 'src/scripts', file);
  let source = fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n');
  const replace = (before, after) => {
    if (source.split(before).length !== 2) throw new Error(`Expected one anchor in ${file}: ${before}`);
    source = source.replace(before, after);
  };
  apply(replace);
  fs.writeFileSync(target, source);
}
const bash = (name, command) => `printf 'PROFILE ${name}.start\\n' >&2\n${command}\nprintf 'PROFILE ${name}.end\\n' >&2`;
const pwsh = (name, command) => `Write-Host 'PROFILE ${name}.start'\n${command}\nWrite-Host 'PROFILE ${name}.end'`;
edit('tools/add_tools.sh', r => {
  const version = '    $tool "$param" 2>/dev/null | sed -Ee "s/[Cc]omposer(.)?$version_regex//g" | grep -Eo "$version_regex" | head -n 1';
  r(version, `    [ "$tool" != phpstan ] || printf 'PROFILE version.start\\n' >&2\n${version}\n    [ "$tool" != phpstan ] || printf 'PROFILE version.end\\n' >&2`);
  const download = '    status_code=$(get -v -e "$tool_path" "${url[@]}")';
  r(download, `    [ "$tool" != phpstan ] || printf 'PROFILE phar-download.start\\n' >&2\n${download}\n    [ "$tool" != phpstan ] || printf 'PROFILE phar-download.end\\n' >&2`);
  const preflight = '      if composer show "$prefix$tool" "$tool_version" -d "$scoped_dir" -a 2>&1 | grep -qE';
  r(preflight, `      printf 'PROFILE composer-preflight.start\\n' >&2\n${preflight}`);
  const require = '      composer require "$prefix$release" -d "$scoped_dir" "$composer_args" >/dev/null 2>&1 || return 1';
  r(require, `      printf 'PROFILE composer-preflight.end\\nPROFILE composer-require.start\\n' >&2\n      composer --profile require "$prefix$release" -d "$scoped_dir" "$composer_args" >"$INSTALL_PROFILE_DIR/composer-require.log" 2>&1 || return 1\n      printf 'PROFILE composer-require.end\\n' >&2`);
  const show = '    composer show "$prefix$tool" -d "$scoped_dir" 2>&1 | grep -E ^versions | sudo tee /tmp/composer.log >/dev/null 2>&1';
  r(show, bash('composer-show', show));
});
edit('tools/add_tools.ps1', r => {
  const version = '    return . $tool $param 2> $null | ForEach-Object { $_ -replace "composer $version_regex", \'\' } | Select-String -Pattern $version_regex | Select-Object -First 1 | ForEach-Object { $_.matches.Value }';
  r(version, `    if ($tool -eq 'phpstan') { Write-Host 'PROFILE version.start' }\n${version.replace('return .', '$profile_result = .')}\n    if ($tool -eq 'phpstan') { Write-Host 'PROFILE version.end' }\n    return $profile_result`);
  const download = '\n        $status_code = (Invoke-WebRequest -Passthru -Uri $url -OutFile $tool_path).StatusCode';
  r(download, `        if ($tool -eq 'phpstan') { Write-Host 'PROFILE phar-download.start' }\n${download}\n        if ($tool -eq 'phpstan') { Write-Host 'PROFILE phar-download.end' }`);
  const preflight = "      if((composer show $prefix$tool $tool_version -d $unix_scoped_dir -a 2>&1 | findstr '^type *: *composer-plugin')";
  r(preflight, `      Write-Host 'PROFILE composer-preflight.start'\n${preflight}`);
  const require = '      composer require $prefix$release -d $unix_scoped_dir $composer_args >$null 2>&1';
  r(require, `      Write-Host 'PROFILE composer-preflight.end'\n${pwsh('composer-require', '      composer --profile require $prefix$release -d $unix_scoped_dir $composer_args > "$env:INSTALL_PROFILE_DIR/composer-require.log" 2>&1')}`);
  const show = "    $log = composer show $prefix$tool -d $unix_scoped_dir 2>&1 | findstr '^versions'";
  r(show, pwsh('composer-show', show));
});
if (process.env.BENCHMARK_METHOD === 'release') {
  edit('extensions/add_extensions.sh', r => {
    const metadata = '  metadata=$(php "${src:?}/scripts/extensions/release.php" "$extension" "$package" "$libc") || return 1';
    r(metadata, bash('metadata', metadata));
    const download = '  [ "$(get -v -n "$archive" "$(echo "$metadata" | jq -r .url)")" = 200 ] || return 1';
    r(download, bash('turbo-download', download) + '\n  printf "PROFILE turbo-archive-bytes %s\\n" "$(wc -c < "$archive")" >&2\n  printf \'PROFILE turbo-install.start\\n\' >&2');
    r('  check_extension "$extension"\n)', '  check_extension "$extension"\n  local profile_status=$?\n  printf \'PROFILE turbo-install.end\\n\' >&2\n  return "$profile_status"\n)');
  });
  edit('extensions/add_extensions.ps1', r => {
    const metadata = '  $metadata = & php "$src\\scripts\\extensions\\release.php" $extension $package \'none\' "vs$($installed.VCVersion)"';
    r(metadata, pwsh('metadata', metadata));
    r('    Get-File -Url $release.url -OutFile $archive', pwsh('turbo-download', '    Get-File -Url $release.url -OutFile $archive') + '\n    Write-Host "PROFILE turbo-archive-bytes $((Get-Item $archive).Length)"\n    Write-Host \'PROFILE turbo-install.start\'');
    r('  } finally {\n    Remove-Item $download_dir', '    Write-Host \'PROFILE turbo-install.end\'\n  } finally {\n    Remove-Item $download_dir');
  });
  edit('extensions/release.php', r => {
    r('        $response = curl_exec($curl);', '        $profileStart = microtime(true);\n        $response = curl_exec($curl);\n        file_put_contents(getenv("INSTALL_PROFILE_DIR") . "/metadata-http.jsonl", json_encode(array("url" => $url, "seconds" => microtime(true) - $profileStart, "bytes" => curl_getinfo($curl, CURLINFO_SIZE_DOWNLOAD), "status" => curl_getinfo($curl, CURLINFO_HTTP_CODE))) . "\\n", FILE_APPEND);');
  });
}
console.log(`Instrumented ${process.env.BENCHMARK_METHOD} at ${root}`);
