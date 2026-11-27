from pathlib import Path
import os,csv
e=os.environ
tmp=Path(e['RUNNER_TEMP'])
mode=e['MODE']
if mode.startswith('header-'):
    ok=mode=='header-404'
    assert e['OUTCOME']==('success' if ok else 'failure'), (mode,e['OUTCOME'])
    headers=(tmp/'headers').read_text().splitlines()
    assert headers==(['404','master'] if ok else [mode[7:]]),headers
    if ok:
        import re
        api=Path(e['EXT_DIR']).name
        assert re.fullmatch(r'[0-9]{8}',api) and Path(e['EXT_DIR']).is_dir()
        assert (tmp/'deps-dir').read_text().endswith('-'+api) and e['CACHE_KEY']
    else:
        assert not any((tmp/f).exists() for f in ['header-filesystem','deps-dir','key','dir'])
        assert not e['EXT_DIR'] and not e['CACHE_KEY']
    print('PASS',mode,headers,e['OUTCOME'])
else:
    assert e['OUTCOME']=='failure'
    rows=list(csv.reader((tmp/(mode+'.tsv')).read_text().splitlines(),delimiter='\t'))
    print('Observed',rows)
    cache=Path((tmp/'deps-dir').read_text())
    assert not list(cache.glob('.download.*'))
    if mode=='unavailable':
        assert len(rows)==2 and all(r[1:3]==['22','503'] for r in rows) and not Path('/tmp/Packages').exists()
    else:
        assert not (cache/'igbinary.so').exists()
        assert not Path('/usr/lib/php/20220829/igbinary.so').exists()
        assert (cache/'msgpack.so').is_file()
        target=[r for r in rows if '/pool/' in r[0] and 'igbinary' in r[0]]
        if mode=='download': assert len(target)==2 and all(r[1:3]==['22','503'] for r in target)
        if mode=='extraction': assert len(target)==1 and target[0][1:3]==['0','200']
        if mode=='copy': assert (tmp/'copy-fault').is_file()
    print('PASS',mode,'failure reached the caller, with no partial cache file')
