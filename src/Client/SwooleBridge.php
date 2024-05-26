<?php

namespace Cesurapp\SwooleBundle\Client;

use Symfony\Contracts\HttpClient\HttpClientInterface;
use Symfony\Contracts\HttpClient\ResponseInterface;
use Symfony\Contracts\HttpClient\ResponseStreamInterface;

class SwooleBridge implements HttpClientInterface
{
    public static ?array $clients = null;

    public function request(string $method, string $url, array $options = []): ResponseInterface
    {
        $client = SwooleClient::create($url)->setMethod($method)->setOptions($options);

        if (isset($options['headers'])) {
            $client->setHeaders($options['headers']);
        }
        if (isset($options['json'])) {
            $client->setJsonData($options['json']);
        }
        if (isset($options['body'])) {
            $client->setData($options['body']);
        }
        if (isset($options['query'])) {
            $client->setQuery($options['query']);
        }

        $response = new SwooleResponse($client->execute());
        if (is_array(self::$clients)) {
            self::$clients[] = $response->getInfo();
        }

        return $response;
    }

    public function stream(ResponseInterface|iterable $responses, ?float $timeout = null): ResponseStreamInterface
    {
        throw new \Exception('Swoole bridge stream not configured!');
    }

    public function withOptions(array $options): static
    {
        return $this;
    }

    public function enableTrace(): void
    {
        self::$clients = [];
    }
}
