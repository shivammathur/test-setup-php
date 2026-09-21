const fs = require('fs');
const cp = require('child_process');
const os = require('os');
const path = require('path');
const phase = process.argv[2];
if (!['before','after'].includes(phase)) throw new Error('Expected before or after');
function run(command,args,options={}) {
  const p=cp.spawnSync(command,args,{encoding:'utf8',timeout:60000,...options});
  return {status:p.status,stdout:(p.stdout||'').trim(),stderr:(p.stderr||'').trim(),error:p.error?.message};
}
function json(result) {try{return JSON.parse(result.stdout.replace(/^\uFEFF/,''));}catch{return null;}}
const php=run('php',['-r','echo json_encode(["version" => PHP_VERSION, "minor" => PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION, "binary" => PHP_BINARY, "machine" => php_uname("m"), "bits" => PHP_INT_SIZE * 8, "memoryLimit" => ini_get("memory_limit"), "extensions" => get_loaded_extensions()]);']);
let system;
if (process.platform==='linux') {
  const release=Object.fromEntries(fs.readFileSync('/etc/os-release','utf8').split('\n').filter(l=>l.includes('=')).map(l=>{const n=l.indexOf('=');return [l.slice(0,n),l.slice(n+1).replace(/^"|"$/g,'')];}));
  system={name:release.PRETTY_NAME,version:release.VERSION_ID,id:release.ID};
} else if(process.platform==='darwin') {
  system={name:'macOS',version:run('sw_vers',['-productVersion']).stdout};
} else {
  const result=run('powershell.exe',['-NoProfile','-Command','Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture | ConvertTo-Json -Compress']);
  const info=json(result);
  system=info?{name:info.Caption,version:info.Version,architecture:info.OSArchitecture}:{error:result};
}
const record={phase,label:process.env.TEST_RUNNER_LABEL,setupSha:process.env.SETUP_PHP_SHA,system,runnerOs:process.env.RUNNER_OS,runnerArch:process.env.RUNNER_ARCH,machine:os.machine(),processArch:process.arch,imageOS:process.env.ImageOS,imageVersion:process.env.ImageVersion,php:{...php,data:json(php)}};
if(phase==='after') {
  record.setupOutcome=process.env.SETUP_OUTCOME;
  record.setupOutput=process.env.SETUP_PHP_VERSION;
  record.composer=process.platform==='win32'?run('cmd.exe',['/d','/s','/c','composer --version --no-ansi']):run('composer',['--version','--no-ansi']);
}
fs.mkdirSync('evidence',{recursive:true});
fs.writeFileSync(path.join('evidence',phase+'.json'),JSON.stringify(record,null,2)+'\n');
console.log(JSON.stringify(record,null,2));
