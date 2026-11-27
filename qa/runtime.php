<?php
if (PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION !== getenv('PHPV')) { exit(2); }
$cache = new Memcached();
$cache->addServer('127.0.0.1',11211);
if (count($cache->getServerList()) !== 1) { exit(3); }
if (PHP_OS_FAMILY === 'Linux') {
  $channel = new Grpc\Channel('localhost:1', ['credentials' => Grpc\ChannelCredentials::createInsecure()]);
  $channel->close();
  $v = new Google\Protobuf\Timestamp(); $v->setSeconds(42);
  $copy = new Google\Protobuf\Timestamp(); $copy->mergeFromString($v->serializeToString());
  if ((int)$copy->getSeconds() !== 42 || !class_exists('DOMDocument')) { exit(4); }
  if (igbinary_unserialize(igbinary_serialize([42])) !== [42] || msgpack_unpack(msgpack_pack([42])) !== [42]) { exit(5); }
}
printf("PASS runtime PHP %s / memcached %s / grpc %s / protobuf %s\n", PHP_VERSION, phpversion('memcached'), phpversion('grpc'), phpversion('protobuf'));
