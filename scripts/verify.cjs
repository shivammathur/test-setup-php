const fs=require('fs');
const label=process.env.TEST_RUNNER_LABEL;
const claim=JSON.parse(fs.readFileSync('claims.json','utf8')).find(c=>c.label===label);
const problems=[];
const read=phase=>{try{return JSON.parse(fs.readFileSync('evidence/'+phase+'.json','utf8'));}catch(e){problems.push(phase+' evidence missing: '+e.message);return null;}};
const before=read('before');
const after=read('after');
const check=(condition,message)=>{if(!condition)problems.push(message);};
if(!claim)throw new Error('Missing README claim for '+label);
if(before){
  const arm=['arm64','aarch64'].includes(claim.architecture);
  check(before.runnerArch===(arm?'ARM64':'X64'),'Runner architecture: expected '+claim.architecture+', got '+before.runnerArch);
  if(claim.environment.startsWith('Ubuntu')){
    check(before.runnerOs==='Linux'&&before.system.id==='ubuntu','Expected Ubuntu, got '+JSON.stringify(before.system));
    check(before.system.version===claim.environment.split(' ')[1],'OS version: expected '+claim.environment+', got '+before.system.version);
  }else if(claim.environment.startsWith('macOS')){
    const major=claim.environment.match(/(\d+)\.x/)[1];
    check(before.runnerOs==='macOS'&&before.system.version.split('.')[0]===major,'OS version: expected '+claim.environment+', got '+JSON.stringify(before.system));
  }else{
    const expected=claim.environment.startsWith('Windows Server')?claim.environment:'Windows 11';
    check(before.runnerOs==='Windows'&&before.system.name?.includes(expected),'OS version: expected '+claim.environment+', got '+JSON.stringify(before.system));
  }
  if(claim.preinstalled===null){
    check(before.php.status!==0,'README says no preinstalled PHP, found '+before.php.data?.version);
  }else{
    check(before.php.status===0&&before.php.data?.minor===claim.preinstalled,'Preinstalled PHP: expected '+claim.preinstalled+', got '+(before.php.data?.version||before.php.error||before.php.stderr));
  }
}
if(after){
  check(after.setupOutcome==='success','setup-php outcome: '+after.setupOutcome);
  check(after.php.status===0&&after.php.data?.minor==='8.5','Expected working PHP 8.5 after setup, got '+JSON.stringify(after.php));
  check(after.setupOutput===after.php.data?.version,'Action version output differs from actual PHP: '+after.setupOutput);
  check(after.php.data?.memoryLimit==='256M','memory_limit was not set to 256M');
  for(const ext of ['curl','mbstring','openssl','xml','zip'])check(after.php.data?.extensions.map(e=>e.toLowerCase()).includes(ext),'Missing extension: '+ext);
  check(after.composer?.status===0&&after.composer.stdout.includes('Composer version'),'Composer did not execute successfully');
}
fs.mkdirSync('evidence',{recursive:true});
const result={label,claim,before,after,problems,passed:problems.length===0};
fs.writeFileSync('evidence/result.json',JSON.stringify(result,null,2)+'\n');
if(process.env.GITHUB_STEP_SUMMARY)fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,'## '+label+'\n\n'+(problems.length?problems.map(p=>'- '+p).join('\n'):'All runner claims and PHP 8.5 setup checks passed.')+'\n');
console.log(JSON.stringify({label,problems,passed:result.passed},null,2));
if(problems.length)process.exitCode=1;
