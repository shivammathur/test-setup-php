import os,subprocess,sys
root=sys.argv[1]
for shell,script in ([('pwsh','runtime.ps1')] if os.name == 'nt' else [('bash','runtime.sh')]):
    for scenario in ['success','failure','cached','retry','no-show','global-failure','no-fallback','both-fail']:
        cmd=[shell]
        if shell=='pwsh': cmd+=['-NoProfile','-File']
        cmd+=[str(__import__('pathlib').Path(__file__).with_name(script)),root,scenario]
        r=subprocess.run(cmd,text=True,capture_output=True)
        expected_fail=scenario in ['no-fallback','both-fail']
        expected_fallback=scenario in ['failure','no-show','global-failure','both-fail']
        assert bool(r.returncode)==expected_fail,(shell,scenario,r.returncode,r.stdout,r.stderr)
        assert ('FALLBACK https://example.com/phpstan.phar phpstan -V' in r.stdout)==expected_fallback,(shell,scenario,r.stdout,r.stderr)
        assert '9.9.9' not in r.stdout,(shell,scenario,r.stdout)
        print(shell,scenario,'PASS',flush=True)
