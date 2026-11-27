<?php
$channel = new Grpc\Channel('localhost:1', ['credentials' => Grpc\ChannelCredentials::createInsecure()]);
$channel->close();
$message = new Google\Protobuf\Timestamp();
$message->setSeconds(42);
$copy = new Google\Protobuf\Timestamp();
$copy->mergeFromString($message->serializeToString());
printf("grpc %s, protobuf %s\n", phpversion('grpc'), phpversion('protobuf'));
exit((int) $copy->getSeconds() === 42 ? 0 : 1);
