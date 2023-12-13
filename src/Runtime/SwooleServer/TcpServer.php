<?php

namespace Cesurapp\SwooleBundle\Runtime\SwooleServer;

use OpenSwoole\Constant;
use OpenSwoole\Process;

readonly class TcpServer
{
    public function __construct(HttpServer $server, private array $options)
    {
        $tcpServer = $server->addlistener('127.0.0.1', 9502, Constant::SOCK_TCP);
        $tcpServer->set(['worker_num' => 1]);
        $tcpServer->on('receive', [$this, 'onReceive']);
    }

    /**
     * Handle TCP Request.
     */
    public function onReceive(HttpServer $server, int $fd, int $fromId, string $command): void
    {
        $cmd = explode('::', $command);
        $server->send($fd, match ($cmd[0]) {
            'shutdown' => $this->cmdShutdown($server),
            'taskRetry' => $this->cmdTaskRetry($server, $cmd[1]),
            'getMetrics' => $this->cmdMetrics($server),
            default => 0
        });
    }

    /**
     * Command Shutdown.
     */
    private function cmdShutdown(HttpServer $server): int
    {
        Process::kill($server->master_pid);

        return 1;
    }

    /**
     * Command Reload Tasks.
     */
    private function cmdTaskRetry(HttpServer $server, string $cmd): int
    {
        $server->task(json_decode($cmd, true, 512, JSON_THROW_ON_ERROR));

        return 1;
    }

    /**
     * Command View Server Metrics.
     */
    private function cmdMetrics(HttpServer $server): string
    {
        $options = $this->options;
        $options['http']['cache_table']['current'] = $server->appCache->count();
        $options['http']['cache_table']['memory_size'] = $server->appCache->memorySize;

        return json_encode([
            'server' => $options,
            'metrics' => $server->stats(),
        ], JSON_THROW_ON_ERROR);
    }
}
