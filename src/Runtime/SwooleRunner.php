<?php

namespace Cesurapp\SwooleBundle\Runtime;

use Cesurapp\SwooleBundle\Runtime\SwooleServer\CronServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\HttpServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\TaskServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\TcpServer;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\Runtime\RunnerInterface;

class SwooleRunner implements RunnerInterface
{
    public static array $config = [
        'worker' => [
            'cron' => 1,
            'task' => 1,
        ],
        'http' => [
            'host' => '0.0.0.0',
            'port' => 80,
            'mode' => SWOOLE_PROCESS,
            'sock_type' => SWOOLE_SOCK_TCP,
            'settings' => [
                'worker_num' => 8,
                'task_worker_num' => 8,
                'enable_static_handler' => false,
                'log_level' => SWOOLE_LOG_WARNING,
                'max_wait_time' => 60,
                'task_enable_coroutine' => true,
                'task_max_request' => 0,
                'package_max_length' => 15 * 1024 * 1024,
                'single_thread' => true,
                'http_compression' => true,
            ],
        ],
    ];

    public function __construct(private readonly HttpKernelInterface $application, array $options)
    {
        self::$config['http']['settings']['worker_num'] = swoole_cpu_num();
        self::$config['http']['settings']['task_worker_num'] = ceil(swoole_cpu_num() / 2);

        self::$config = $this->replaceRuntimeEnv(self::$config);
        if (self::$config['worker']['task']) {
            self::$config['worker']['cron'] = true;
        }
        if (0 === self::$config['http']['settings']['task_worker_num']) {
            self::$config['worker']['task'] = false;
        }
        if (false === self::$config['worker']['task']) {
            self::$config['http']['settings']['task_worker_num'] = 0;
        }

        self::$config['env'] = $_ENV[$options['env_var_name']];
        self::$config['debug'] = $options['debug'];
        self::$config['worker']['watch'] = (bool) ($_SERVER['watch'] ?? false);

        // Setup Debug Mode MaxRequest
        if (self::$config['debug']) {
            self::$config['http']['settings']['max_request'] = 15;
        }
    }

    private function assignArrayByPath(array &$arr, string $path, mixed $value): void
    {
        $keys = explode('.', $path);

        foreach ($keys as $key) {
            $arr = &$arr[$key];
        }

        $arr = $value;
    }

    private function replaceRuntimeEnv(array $options): array
    {
        $opts = array_merge_recursive(
            array_filter($_ENV, static fn ($k) => str_starts_with($k, 'SERVER_WORKER'), ARRAY_FILTER_USE_KEY),
            array_filter($_ENV, static fn ($k) => str_starts_with($k, 'SERVER_HTTP'), ARRAY_FILTER_USE_KEY)
        );

        $parseType = static function (mixed $type) {
            if (is_numeric($type)) {
                return (int) $type;
            }

            return match ($type) {
                'false' => false,
                'true' => true,
                default => $type,
            };
        };

        foreach ($opts as $key => $value) {
            $this->assignArrayByPath($options, strtolower(preg_replace(['/SERVER_/', '/_/'], ['', '.'], $key, 2)), $parseType($value));
        }

        return $options;
    }

    public function run(): int
    {
        $httpServer = new HttpServer($this->application, self::$config);
        new TaskServer($this->application, $httpServer, self::$config);
        new CronServer($this->application, $httpServer, self::$config);
        new TcpServer($httpServer, self::$config);

        return (int) $httpServer->start();
    }
}
