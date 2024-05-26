<?php

namespace Cesurapp\SwooleBundle\Client;

use Symfony\Bundle\FrameworkBundle\DataCollector\TemplateAwareDataCollectorInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\DataCollector\DataCollector;

class ClientDataCollector extends DataCollector implements TemplateAwareDataCollectorInterface
{
    public function collect(Request $request, Response $response, ?\Throwable $exception = null): void
    {
        $this->data['clients'] = SwooleBridge::$clients ?? [];
        $this->data['count'] = count($this->data['clients']);
    }

    public function getCount(): int
    {
        return $this->data['count'] ?? 0;
    }

    public function getClients(): array
    {
        return $this->data['clients'] ?? [];
    }

    public function getName(): string
    {
        return static::class;
    }

    public static function getTemplate(): ?string
    {
        return '@Swoole/client_data_collector.html.twig';
    }
}
