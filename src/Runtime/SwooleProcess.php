<?php

namespace Cesurapp\SwooleBundle\Runtime;

use OpenSwoole\Client;
use OpenSwoole\Constant;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Process\ExecutableFinder;
use Symfony\Component\Process\PhpExecutableFinder;
use Symfony\Component\Process\Process as SymfonyProcess;

class SwooleProcess
{
    public function __construct(private readonly SymfonyStyle $output, private string $rootDir, private string $entrypoint)
    {
        $this->rootDir = rtrim($this->rootDir, '/');
        $this->entrypoint = '/'.ltrim($entrypoint, '/');
    }

    /**
     * Start Server.
     */
    public function start(string $phpBinary, bool $detach = false): bool
    {
        if ($this->getServer()?->isConnected()) {
            $this->output->warning('Swoole HTTP Server is Running');

            return false;
        }

        // Start
        exec(sprintf('%s %s%s %s', $phpBinary, $this->rootDir, $this->entrypoint, $detach ? '> /dev/null &' : ''));

        $this->output->success('Swoole HTTP Server is Started');

        return true;
    }

    /**
     * Start Watch Server.
     */
    public function watch(array $watchDir, array $watchExt): void
    {
        // Check fsWatch Plugin
        if (!$fsWatch = (new ExecutableFinder())->find('fswatch')) {
            $this->output->error('fswatch plugin not found!');

            return;
        }

        // Start File Watcher
        $paths = [...array_map(fn ($path) => $this->rootDir.$path, $watchDir)];
        $watcher = new SymfonyProcess([$fsWatch, ...$watchExt, '-r', '-e', '.*~', ...$paths], null, null, null, 0);
        $watcher->start();

        // App Server
        $server = new SymfonyProcess([(new PhpExecutableFinder())->find(), $this->rootDir.$this->entrypoint], null, null, null, 0);
        $server->setTty(true)->start();

        while (true) { // @phpstan-ignore-line
            if ($output = $watcher->getIncrementalOutput()) {
                $this->output->write('Changed -> '.str_replace($this->rootDir, '', $output));
                $server->stop();
                $server->start(null, ['watch' => random_int(100, 200)]);
            }
            usleep(100 * 1000);
        }
    }

    /**
     * Stop Server.
     */
    public function stop(string $tcpHost = null, int $tcpPort = null): bool
    {
        $server = $this->getServer($tcpHost ?? '127.0.0.1', $tcpPort ?? 9502);
        if (!$server || !$server->isConnected()) {
            $this->output->error('Swoole HTTP server not found!');

            return false;
        }

        // Shutdown
        try {
            $server->send('shutdown');
            $server->close();
        } catch (\Exception $exception) {
            $this->output->error($exception->getMessage());
        }

        $this->output->success('Swoole HTTP Server is Stopped!');

        return true;
    }

    /**
     * Get Current Process ID.
     */
    public function getServer(string $tcpHost = null, int $tcpPort = null): ?Client
    {
        $tcpClient = new Client(Constant::SOCK_TCP);

        try {
            @$tcpClient->connect($tcpHost ?? '127.0.0.1', $tcpPort ?? 9502, 1);
            if (!$tcpClient->isConnected()) {
                return null;
            }
        } catch (\Exception) {
            return null;
        }

        return $tcpClient;
    }
}
