import ctypes as C
import json
import os
from pathlib import Path

root = Path('deps').resolve()
handles = [os.add_dll_directory(str(p)) for p in {x.parent for x in root.rglob('*.dll')}]
glib = C.CDLL(str(root / 'bin/glib-2.dll'))
assert [C.c_uint.in_dll(glib, 'glib_' + x + '_version').value for x in ['major', 'minor', 'micro']] == [2, 90, 1]
enchant = C.CDLL(str(root / 'bin/libenchant2.dll'))
def function(name, result, *arguments):
    value = getattr(enchant, name)
    value.restype, value.argtypes = result, list(arguments)
    return value
assert function('enchant_get_version', C.c_char_p)() == b'2.8.21'
broker = function('enchant_broker_init', C.c_void_p)()
assert broker
filename = Path('candidate.pwl').resolve()
filename.write_text('hello\nworld\n', encoding='utf-8')
dictionary = function('enchant_broker_request_pwl_dict', C.c_void_p, C.c_void_p, C.c_char_p)(broker, str(filename).encode())
assert dictionary
try:
    check = function('enchant_dict_check', C.c_int, C.c_void_p, C.c_char_p, C.c_ssize_t)
    assert check(dictionary, b'hello', -1) == 0
    assert check(dictionary, b'mispelledword', -1) > 0
finally:
    function('enchant_broker_free_dict', None, C.c_void_p, C.c_void_p)(broker, dictionary)
    function('enchant_broker_free', None, C.c_void_p)(broker)
Path('reports/enchant-runtime.json').write_text(json.dumps({'passed': True, 'glib': '2.90.1', 'enchant': '2.8.21', 'personalWordList': True}))
print('Enchant personal word list passed with GLib 2.90.1')
