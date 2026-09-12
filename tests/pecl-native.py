"""Exercise freshly rebuilt PECL dependency DLLs with their selected runtimes."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('library', choices=['librdkafka', 'librabbitmq-c', 'librrd'])
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--deps', required=True, type=Path)
parser.add_argument('--openssl')
parser.add_argument('--report', required=True, type=Path)
args = parser.parse_args()
handles = []
for root in [args.root, args.deps]:
    dirs = {p.parent.resolve() for p in root.rglob('*.dll')}
    handles.extend(os.add_dll_directory(str(p)) for p in sorted(dirs))
result = {'library': args.library, 'pointerBits': struct.calcsize('P') * 8, 'checks': []}

def function(dll, name, restype, *argtypes):
    f = getattr(dll, name)
    f.restype, f.argtypes = restype, list(argtypes)
    return f

def load(pattern):
    files = list(args.root.rglob(pattern))
    assert len(files) == 1, (pattern, files)
    return C.CDLL(str(files[0].resolve()))

if args.openssl:
    crypto = list(args.deps.rglob('libcrypto-*.dll'))
    assert len(crypto) == 1, crypto
    dll = C.CDLL(str(crypto[0].resolve()))
    result['openssl'] = function(dll, 'OpenSSL_version', C.c_char_p, C.c_int)(0).decode()
    assert result['openssl'].startswith('OpenSSL ' + args.openssl + ' '), result
    result['checks'].append('selected OpenSSL runtime version')

if args.library == 'librabbitmq-c':
    dll = load('rabbitmq.4.dll')
    result['version'] = function(dll, 'amqp_version', C.c_char_p)().decode()
    assert result['version'] == '0.17.0', result
    new = function(dll, 'amqp_new_connection', C.c_void_p)
    free = function(dll, 'amqp_destroy_connection', C.c_int, C.c_void_p)
    socket = function(dll, 'amqp_ssl_socket_new', C.c_void_p, C.c_void_p)
    connection = new()
    assert connection
    try:
        assert socket(connection), 'Unable to initialize RabbitMQ TLS context'
    finally:
        assert free(connection) == 0
    result['checks'].extend(['connection lifecycle', 'TLS socket initialization'])
elif args.library == 'librdkafka':
    dll = load('librdkafka.dll')
    result['version'] = function(dll, 'rd_kafka_version_str', C.c_char_p)().decode()
    assert result['version'] == '2.15.1', result
    conf = function(dll, 'rd_kafka_conf_new', C.c_void_p)()
    setconf = function(dll, 'rd_kafka_conf_set', C.c_int, C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_size_t)
    error = C.create_string_buffer(1024)
    for key, value in [(b'security.protocol', b'ssl'), (b'log_level', b'0'), (b'enable.idempotence', b'true')]:
        assert setconf(conf, key, value, error, len(error)) == 0, error.value
    producer = function(dll, 'rd_kafka_new', C.c_void_p, C.c_int, C.c_void_p, C.c_char_p, C.c_size_t)(0, conf, error, len(error))
    if not producer:
        function(dll, 'rd_kafka_conf_destroy', None, C.c_void_p)(conf)
        raise RuntimeError(error.value.decode())
    function(dll, 'rd_kafka_destroy', None, C.c_void_p)(producer)
    result['checks'].extend(['SSL configuration', 'idempotent producer lifecycle'])
else:
    dll = load('librrd-8.dll')
    result['version'] = function(dll, 'rrd_strversion', C.c_char_p)().decode()
    assert result['version'] == '1.11.0', result
    get_error = function(dll, 'rrd_get_error', C.c_char_p)
    clear_error = function(dll, 'rrd_clear_error', None)
    def invoke(name, values, pointer=False):
        clear_error()
        encoded = [str(v).encode() for v in values]
        argv = (C.c_char_p * len(encoded))(*encoded)
        value = function(dll, name, C.c_void_p if pointer else C.c_int, C.c_int, C.POINTER(C.c_char_p))(len(argv), argv)
        assert value if pointer else value == 0, (name, get_error())
        return value
    stamp = int(time.time()) // 60 * 60 - 1200
    database, picture = 'native-rrd-test.rrd', 'native-rrd-graph.png'
    Path(database).unlink(missing_ok=True)
    invoke('rrd_create', ['create', database, '--start', stamp, '--step', 60,
                        'DS:value:GAUGE:120:U:U', 'RRA:AVERAGE:0.5:1:100'])
    invoke('rrd_update', ['update', database] + [f'{stamp + n*60}:{n*3}' for n in range(1, 11)])
    info = invoke('rrd_graph_v', ['graph', picture, '--start', stamp, '--end', stamp+660,
        '--width', 160, '--height', 80, '--title', 'PHP Windows dependency QA',
        f'DEF:v={database}:value:AVERAGE', 'LINE1:v#FF0000:value'], pointer=True)
    function(dll, 'rrd_info_free', None, C.c_void_p)(info)
    data = Path(picture).read_bytes()
    assert data.startswith(b'\x89PNG\r\n\x1a\n') and len(data) > 1000
    result['checks'].extend(['RRD create', 'RRD update', 'Pango/Cairo PNG graph with text'])

args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
