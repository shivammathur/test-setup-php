#!/usr/bin/env python3
"""Experimental runtime filter for measuring published PHP 5 archives.

This is a benchmark candidate, not a replacement for dependency-aware packaging
from the MacPorts build registry. Keep the output isolated until validated.
"""
import json
import posixpath
import re
import sys
import tarfile

source, destination, report = sys.argv[1:]
legal = re.compile(r'(^|/)(copying[^/]*|copyright[^/]*|licen[sc]e[^/]*|notice[^/]*)$', re.I)
documentation = re.compile(r'(^|/)share/(doc|man|info|gtk-doc)(/|$)')
tools = {'pear', 'peardev', 'pecl', 'autoconf', 'autoheader', 'autom4te',
         'autoreconf', 'autoscan', 'autoupdate', 'ifnames', 'glibtool',
         'glibtoolize', 'libtoolize', 'pkg-config', 'gm4', 'gsed', 'daemondo'}


def keep(name):
    path = name.removeprefix('./').removeprefix('opt/local/')
    if legal.search(path):
        return True
    if documentation.search(path):
        return False
    if path.startswith(('Library/Frameworks/', 'lib/perl5/', 'lib/python',
                        'lib/texi2any/', 'share/texi2any/',
                        'include/python', 'lib/pkgconfig/python')):
        return False
    if path.startswith('libexec/boost/'):
        return path.endswith('.dylib') and 'libboost_python' not in path
    if path.startswith('bin/'):
        tool = path[4:]
        return not tool.startswith('python') and (
            tool.startswith('php') or tool in tools or tool.endswith('-config'))
    if path.startswith('sbin/'):
        return path[5:].startswith('php-fpm')
    return True


with tarfile.open(source) as src:
    members = src.getmembers()
    by_name = {m.name.removeprefix('./'): m for m in members}
    selected = {name for name in by_name if keep(name)}
    # Drop aliases to removed tools/data. Preserve hard-link content when the
    # original inode's first archive entry was omitted.
    changed = True
    while changed:
        changed = False
        for name in tuple(selected):
            m = by_name[name]
            if not m.issym():
                continue
            target = m.linkname
            if target.startswith('/opt/local/'):
                target = target[1:]
            elif not target.startswith('/'):
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if target in by_name and target not in selected:
                selected.remove(name)
                changed = True
    counts = {'original_files': len(members), 'original_bytes': sum(m.size for m in members),
              'candidate_files': len(selected), 'candidate_bytes': 0}
    with tarfile.open(destination, 'w', format=tarfile.PAX_FORMAT) as dst:
        for m in members:
            if m.name.removeprefix('./') not in selected:
                continue
            if m.islnk() and m.linkname.removeprefix('./') not in selected:
                content = src.extractfile(m)
                m.type = tarfile.REGTYPE
                m.size = by_name[m.linkname.removeprefix('./')].size
                m.linkname = ''
            else:
                content = src.extractfile(m) if m.isfile() else None
            counts['candidate_bytes'] += m.size
            dst.addfile(m, content)
    with open(report, 'w') as out:
        json.dump(counts, out, indent=2)
    print(json.dumps(counts, indent=2))
