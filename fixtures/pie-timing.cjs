const fs=require('node:fs');
fs.mkdirSync('artifacts',{recursive:true});
const file='artifacts/pie-timing.json';
if(process.argv[2]==='sanitize') {
  for(const name of fs.readdirSync('artifacts').filter(n=>n.startsWith('pie-')&&n.endsWith('.log'))) {
    const p='artifacts/'+name; let contents=fs.readFileSync(p,'utf8');
    for(const key of ['GITHUB_TOKEN','COMPOSER_TOKEN']) if(process.env[key]) contents=contents.split(process.env[key]).join('[REDACTED]');
    fs.writeFileSync(p,contents);
  }
} else {
  const data=fs.existsSync(file)?JSON.parse(fs.readFileSync(file)):{};
  const label=process.argv[3];
  if(process.argv[2]==='start') data[label]={started:Date.now()};
  else {data[label].seconds=(Date.now()-data[label].started)/1000;console.log(label+': '+data[label].seconds+'s');}
  fs.writeFileSync(file,JSON.stringify(data,null,2));
}
