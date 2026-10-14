<?php
$variant = $argv[1];
$args = json_decode(file_get_contents($argv[2]), true);
$file = tempnam(sys_get_temp_dir(), 'PR11669');
$code = 'echo "Test\n"; fprintf(STDERR, "Error");';
file_put_contents($file, '<?php '.$code);
$baseline = array_merge([PHP_BINARY], $args, ['-d', 'opcache.cache_id=diagnose-'.$variant]);
if ($variant === 'no-child-jit') array_push($baseline, '-d', 'opcache.jit_buffer_size=0', '-d', 'opcache.jit=disable');
if ($variant === 'no-child-file-cache') array_push($baseline, '-d', 'opcache.file_cache=');
echo json_encode(['config' => ['variant'=>$variant,'version'=>PHP_VERSION,'zts'=>PHP_ZTS,'opcache'=>ini_get('opcache.enable_cli'),'jit'=>ini_get('opcache.jit'),'cache_id'=>ini_get('opcache.cache_id'),'file_cache'=>ini_get('opcache.file_cache')]]), "\n";
$outputFile = $file.'.out';
for ($repeat=0; $repeat<8; $repeat++) {
 foreach (['pipe', 'filename', 'file', 'inherited'] as $phase) {
  $command=$baseline;
  if ($variant === 'unique-child-cache') array_push($command, '-d', 'opcache.cache_id=child-'.$repeat.'-'.$phase);
  array_push($command, ...($variant === 'inline' ? ['-r', $code] : [$file]));
  $stream=null;
  $spec=match($phase) {
   'pipe'=>[1=>['pipe','w'],2=>['redirect',1]],
   'filename'=>[1=>['file',$outputFile,'w'],2=>['redirect',1]],
   'file'=>[1=>$stream=fopen($outputFile,'w'),2=>['redirect',1]],
   'inherited'=>[2=>['redirect',1]],
  };
  $proc=proc_open($command,$spec,$pipes);
  $output=$phase==='pipe'?stream_get_contents($pipes[1]):null;
  if ($phase==='pipe') fclose($pipes[1]);
  $exit=proc_close($proc);
  if ($stream) fclose($stream);
  if ($phase==='filename'||$phase==='file') {$output=file_get_contents($outputFile);unlink($outputFile);}
  echo "\nRESULT ",json_encode(['repeat'=>$repeat,'phase'=>$phase,'exit'=>$exit,'output'=>$output]),"\n";
 }
}
unlink($file);
