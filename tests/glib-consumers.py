"""Exercise the exact candidate/published Cairo, Pango and RRDtool DLLs."""
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import time

root = Path('deps').resolve()
handles = [os.add_dll_directory(str(p)) for p in sorted({x.parent for x in root.rglob('*.dll')})]
report = {'pointer_bits': struct.calcsize('P') * 8, 'checks': [], 'files': {}}

def load(name):
    path = root / 'bin' / name
    assert path.is_file(), path
    report['files'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return C.CDLL(str(path))

def function(dll, name, result, *arguments):
    f = getattr(dll, name)
    f.restype, f.argtypes = result, list(arguments)
    return f

glib = load('glib-2.dll')
assert [C.c_uint.in_dll(glib, 'glib_' + part + '_version').value for part in ['major', 'minor', 'micro']] == [2, 90, 0]
enchant = load('libenchant2.dll')
assert function(enchant, 'enchant_get_version', C.c_char_p)() == b'2.8.21'
broker = function(enchant, 'enchant_broker_init', C.c_void_p)()
assert broker
dictionary_file = Path('candidate.pwl').resolve()
dictionary_file.write_text('hello\nworld\n', encoding='utf-8')
dictionary = function(enchant, 'enchant_broker_request_pwl_dict', C.c_void_p, C.c_void_p, C.c_char_p)(broker, str(dictionary_file).encode())
assert dictionary
try:
    check = function(enchant, 'enchant_dict_check', C.c_int, C.c_void_p, C.c_char_p, C.c_ssize_t)
    assert check(dictionary, b'hello', -1) == 0
    assert check(dictionary, b'mispelledword', -1) > 0
finally:
    function(enchant, 'enchant_broker_free_dict', None, C.c_void_p, C.c_void_p)(broker, dictionary)
    function(enchant, 'enchant_broker_free', None, C.c_void_p)(broker)
report['checks'].extend(['GLib 2.90.0 version', 'Enchant 2.8.21 version', 'Enchant personal word list'])
cairo = load('cairo-2.dll')
pango = load('pango-1.0-0.dll')
pangocairo = load('pangocairo-1.0-0.dll')
gobject_paths = list((root / 'bin').glob('*gobject*.dll'))
assert len(gobject_paths) == 1, gobject_paths
gobject = C.CDLL(str(gobject_paths[0]))
assert function(cairo, 'cairo_version_string', C.c_char_p)() == b'1.18.6'
assert function(pango, 'pango_version_string', C.c_char_p)() == b'1.58.2'
surface = function(cairo, 'cairo_image_surface_create', C.c_void_p, C.c_int, C.c_int, C.c_int)(0, 320, 120)
assert surface
status = function(cairo, 'cairo_surface_status', C.c_int, C.c_void_p)
assert status(surface) == 0
context = function(cairo, 'cairo_create', C.c_void_p, C.c_void_p)(surface)
assert context
layout = function(pangocairo, 'pango_cairo_create_layout', C.c_void_p, C.c_void_p)(context)
assert layout
description = function(pango, 'pango_font_description_from_string', C.c_void_p, C.c_char_p)(b'Segoe UI 18')
assert description
try:
    rgb = function(cairo, 'cairo_set_source_rgb', None, C.c_void_p, C.c_double, C.c_double, C.c_double)
    rgb(context, 1, 1, 1)
    function(cairo, 'cairo_paint', None, C.c_void_p)(context)
    rgb(context, 0.1, 0.2, 0.8)
    text = 'GLib QA: English العربية हिन्दी'.encode('utf-8')
    function(pango, 'pango_layout_set_text', None, C.c_void_p, C.c_char_p, C.c_int)(layout, text, len(text))
    function(pango, 'pango_layout_set_font_description', None, C.c_void_p, C.c_void_p)(layout, description)
    width, height = C.c_int(), C.c_int()
    function(pango, 'pango_layout_get_pixel_size', None, C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_int))(layout, C.byref(width), C.byref(height))
    assert width.value > 20 and height.value > 5, (width.value, height.value)
    function(pangocairo, 'pango_cairo_show_layout', None, C.c_void_p, C.c_void_p)(context, layout)
    assert function(cairo, 'cairo_status', C.c_int, C.c_void_p)(context) == 0
    assert function(cairo, 'cairo_surface_write_to_png', C.c_int, C.c_void_p, C.c_char_p)(surface, b'pango-cairo.png') == 0
    copy = function(cairo, 'cairo_image_surface_create_from_png', C.c_void_p, C.c_char_p)(b'pango-cairo.png')
    assert status(copy) == 0
    assert function(cairo, 'cairo_image_surface_get_width', C.c_int, C.c_void_p)(copy) == 320
    function(cairo, 'cairo_surface_destroy', None, C.c_void_p)(copy)
finally:
    function(pango, 'pango_font_description_free', None, C.c_void_p)(description)
    function(gobject, 'g_object_unref', None, C.c_void_p)(layout)
    function(cairo, 'cairo_destroy', None, C.c_void_p)(context)
    function(cairo, 'cairo_surface_destroy', None, C.c_void_p)(surface)
report['checks'].extend(['Cairo 1.18.6 version', 'Pango 1.58.2 version', 'multilingual text shaping/rendering', 'Cairo PNG write/read'])

rrd = load('librrd-8.dll')
assert function(rrd, 'rrd_strversion', C.c_char_p)() == b'1.11.0'
get_error = function(rrd, 'rrd_get_error', C.c_char_p)
clear_error = function(rrd, 'rrd_clear_error', None)

def invoke(name, values, pointer=False):
    clear_error()
    encoded = [str(v).encode() for v in values]
    argv = (C.c_char_p * len(encoded))(*encoded)
    value = function(rrd, name, C.c_void_p if pointer else C.c_int, C.c_int, C.POINTER(C.c_char_p))(len(argv), argv)
    assert value if pointer else value == 0, (name, get_error())
    return value

stamp = int(time.time()) // 60 * 60 - 1200
database = 'native-rrd-test.rrd'
Path(database).unlink(missing_ok=True)
invoke('rrd_create', ['create', database, '--start', stamp, '--step', 60, 'DS:value:GAUGE:120:U:U', 'RRA:AVERAGE:0.5:1:100'])
invoke('rrd_update', ['update', database] + [f'{stamp + n * 60}:{n * 3}' for n in range(1, 11)])
# Windows RRDtool uses 64-bit time_t on both target architectures.
start, end, step = C.c_int64(stamp), C.c_int64(stamp + 600), C.c_ulong(60)
count = C.c_ulong()
names = C.POINTER(C.c_char_p)()
values = C.POINTER(C.c_double)()
fetch = function(rrd, 'rrd_fetch_r', C.c_int, C.c_char_p, C.c_char_p, C.POINTER(C.c_int64), C.POINTER(C.c_int64), C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_char_p)), C.POINTER(C.POINTER(C.c_double)))
assert fetch(database.encode(), b'AVERAGE', C.byref(start), C.byref(end), C.byref(step), C.byref(count), C.byref(names), C.byref(values)) == 0, get_error()
assert count.value == 1 and names[0] == b'value'
rows = (end.value - start.value) // step.value
assert any(math.isfinite(values[n]) and values[n] > 0 for n in range(rows))
free = function(rrd, 'rrd_freemem', None, C.c_void_p)
# Read pointer values without ctypes converting the C strings to Python bytes.
name_pointers = C.cast(names, C.POINTER(C.c_void_p))
for n in range(count.value):
    free(name_pointers[n])
free(names)
free(values)
info = invoke('rrd_graph_v', ['graph', 'rrd-graph.png', '--start', stamp, '--end', stamp + 660, '--width', 240, '--height', 100, '--title', 'GLib 2.90.0 dependency QA', f'DEF:v={database}:value:AVERAGE', 'LINE1:v#FF0000:value'], pointer=True)
function(rrd, 'rrd_info_free', None, C.c_void_p)(info)
for filename in ['pango-cairo.png', 'rrd-graph.png']:
    data = Path(filename).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n') and len(data) > 1000
    assert struct.unpack('>II', data[16:24])[0] > 0
report['checks'].extend(['RRDtool version', 'RRD create/update/fetch', 'RRD static dependency PNG graph', 'consumer PNG signatures and dimensions'])
Path('reports/consumer-runtime.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
