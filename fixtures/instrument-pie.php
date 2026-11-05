<?php
declare(strict_types=1);

function wrapMethod(string $code, string $name, string $metadata): string
{
    $tokens = token_get_all($code);
    $offset = 0;
    $function = false;
    $matched = false;
    $start = null;
    $depth = 0;
    foreach ($tokens as $token) {
        $text = is_array($token) ? $token[1] : $token;
        if ($start === null && is_array($token) && $token[0] === T_FUNCTION) {
            $function = true;
            $matched = false;
        } elseif ($start === null && $function && is_array($token) && $token[0] === T_STRING) {
            $matched = $text === $name;
            $function = false;
        }
        if ($matched && $text === '{') {
            if ($depth++ === 0) {
                $start = $offset + 1;
            }
        } elseif ($matched && $text === '}' && --$depth === 0) {
            $body = substr($code, $start, $offset - $start);
            $wrapped = '\n$pieProfileStart = microtime(true); try {' . $body . '} finally { ';
            $wrapped .= '$pieProfileRecord = ' . $metadata . '; $pieProfileRecord["seconds"] = microtime(true) - $pieProfileStart; ';
            $wrapped .= 'file_put_contents(getenv("PIE_PROFILE_FILE"), json_encode($pieProfileRecord) . PHP_EOL, FILE_APPEND); }\n';
            $wrapped = str_replace('\\n', "\n", $wrapped);
            return substr_replace($code, $wrapped, $start, $offset - $start);
        }
        $offset += strlen($text);
    }
    throw new RuntimeException('Could not instrument method ' . $name);
}

$target = getenv('PIE_PROFILE_PHAR');
if (!copy($argv[1], $target)) {
    throw new RuntimeException('Could not copy PIE');
}
$phar = new Phar($target);
$phar->startBuffering();
$processPath = 'src/Util/Process.php';
$phar[$processPath] = wrapMethod($phar[$processPath]->getContent(), 'run', '["kind" => "process", "program" => basename($command[0]), "operation" => $command[1] ?? "", "codeHash" => isset($command[2]) ? hash("sha256", $command[2]) : null]');
$httpPath = 'vendor/composer/composer/src/Composer/Util/HttpDownloader.php';
$http = $phar[$httpPath]->getContent();
foreach (['get', 'copy'] as $method) {
    $http = wrapMethod($http, $method, '["kind" => "http", "method" => "' . $method . '", "url" => strtok($url, "?")]');
}
$http = preg_replace('/(private function addJob\(array \$request, bool \$sync = false\): array\s*\{)/', '$1' . "\n" . 'file_put_contents(getenv("PIE_PROFILE_FILE"), json_encode(["kind" => "http-request", "url" => strtok($request["url"], "?")]) . PHP_EOL, FILE_APPEND);', $http, 1, $count);
if ($count !== 1) {
    throw new RuntimeException('Could not instrument HTTP jobs');
}
$phar[$httpPath] = $http;
$phar->stopBuffering();
chmod($target, 0755);
