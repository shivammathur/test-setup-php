<?php
$required = explode(',', $argv[1]);
foreach (array_map('trim', $required) as $name) {
    if ($name === '' || ($name === 'sysvshm' && PHP_OS_FAMILY === 'Windows')) {
        continue;
    }
    if (!extension_loaded($name)) {
        fwrite(STDERR, "$name is missing\n");
        exit(1);
    }
    printf("%s %s\n", $name, phpversion($name));
}
if (in_array('grpc', array_map('trim', $required), true)) {
    $channel = new Grpc\Channel('localhost:1', ['credentials' => Grpc\ChannelCredentials::createInsecure()]);
    $channel->close();
    if (isset($argv[2]) && version_compare(phpversion('grpc'), '1.83.0', '<')) {
        exit(1);
    }
}
if (in_array('protobuf', array_map('trim', $required), true)) {
    $value = new Google\Protobuf\Timestamp();
    $value->setSeconds(42);
    $copy = new Google\Protobuf\Timestamp();
    $copy->mergeFromString($value->serializeToString());
    if ((int) $copy->getSeconds() !== 42) {
        exit(1);
    }
}
