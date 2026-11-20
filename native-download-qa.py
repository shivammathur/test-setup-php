import http.server,threading,subprocess,tempfile,pathlib,tarfile,io,os,shutil
has_retry_all='--retry-all-errors' in subprocess.run(['curl','--help','all'],capture_output=True,text=True).stdout
counts={};ext='setup_php_native_retry_qa';dirname=ext+'-1'
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w:gz') as t:
 x=tarfile.TarInfo(dirname+'/config.m4');x.size=2;t.addfile(x,io.BytesIO(b'ok'))
payload=buf.getvalue()
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  counts[self.path]=counts.get(self.path,0)+1;n=counts[self.path]
  if self.path=='/missing':self.send_error(404);return
  if self.path=='/server' or ('/transient/' in self.path and n<3):self.send_error(503);return
  data=payload if '/archive/' in self.path else b'ok'
  bad=self.path=='/bad' or ('/partial/' in self.path and n<3)
  self.send_response(200);self.send_header('Content-Length',len(data)+100 if bad else len(data));self.end_headers();self.wfile.write(data[:2] if bad else data);self.close_connection=True
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory() as d:
 script=r'''
. "${SETUP_PHP_TEST_ROOT}/src/scripts/unix.sh"
. "${SETUP_PHP_TEST_ROOT}/src/scripts/extensions/source.sh"
sudo() { "$@"; }
runner=github
curl_opts=(-sL)
status=$(get -v -e "$test_dir/bad" "$base/bad") && exit 1
[ "$status" = 000 ] && [ ! -e "$test_dir/bad" ] || exit 2
get -q -n "$test_dir/server" "$base/server" && exit 3
[ ! -e "$test_dir/server" ] || exit 4
get -q -e "$test_dir/ok" "$base/missing" "$base/ok" || exit 5
[ "$(cat "$test_dir/ok")" = ok ] && [ -x "$test_dir/ok" ] || exit 6
url=$base
repo=$ext
release=1
sub_dir=.
org=partial
if [ "$has_retry_all" = true ]; then
  fetch_extension "$ext" get || exit 7
  [ "$(cat config.m4)" = ok ] || exit 8
else
  fetch_extension "$ext" get && exit 7
  [ ! -e /tmp/"$ext".tar.gz ] || exit 8
fi
[ "${#curl_opts[@]}" = 1 ] && [ "${curl_opts[0]}" = -sL ] || exit 9
# Emulate a legacy curl without --retry-all-errors.
curl() { if [ "$1" = --help ]; then return 2; else command curl "$@"; fi; }
org=transient
fetch_extension "$ext" get || exit 10
[ "$(cat config.m4)" = ok ] || exit 11
[ "${#curl_opts[@]}" = 1 ] || exit 12
'''
 try:subprocess.run(['bash','-c',script],env={**os.environ,'base':f'http://127.0.0.1:{server.server_port}','test_dir':d,'ext':ext,'has_retry_all':str(has_retry_all).lower()},check=True)
 finally:shutil.rmtree('/tmp/'+dirname,ignore_errors=True);pathlib.Path('/tmp/'+ext+'.tar.gz').unlink(missing_ok=True)
 expected={'/bad':1,'/server':1,'/missing':1,'/ok':1,f'/partial/{ext}/archive/1.tar.gz':3 if has_retry_all else 1,f'/transient/{ext}/archive/1.tar.gz':3}
 assert counts==expected,(counts,expected)
 print('PASS: get makes one attempt per URL; source fetch uses native retries; old curl avoids unsupported flags; retry options do not leak',counts)
server.shutdown()
