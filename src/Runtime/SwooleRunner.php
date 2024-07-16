<?php

namespace Cesurapp\SwooleBundle\Runtime;

use Cesurapp\SwooleBundle\Runtime\SwooleServer\CronServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\HttpServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\TaskServer;
use Cesurapp\SwooleBundle\Runtime\SwooleServer\TcpServer;
use OpenSwoole\Constant;
use OpenSwoole\Server;
use OpenSwoole\Util;
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
            'mode' => Server::POOL_MODE,
            'sock_type' => Constant::SOCK_TCP,
            'settings' => [
                'worker_num' => 8,
                'task_worker_num' => 8,
                'enable_static_handler' => false,
                'log_level' => Constant::LOG_WARNING,
                'max_wait_time' => 60,
                'task_enable_coroutine' => true,
                'task_max_request' => 0,
            ],
        ],
    ];

    public function __construct(private readonly HttpKernelInterface $application, array $options)
    {
        self::$config['http']['settings']['worker_num'] = Util::getCPUNum();
        self::$config['http']['settings']['task_worker_num'] = ceil(Util::getCPUNum() / 2);

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

    private function replaceRuntimeEnv(array $options, ?string $parentKey = null): array
    {
        $parseType = static function (mixed $type) {
            return match ($type) {
                'false' => false,
                'true' => true,
                is_numeric($type) => (int) $type,
                default => $type
            };
        };

        foreach ($options as $key => $option) {
            if (is_array($option)) {
                $options[$key] = $this->replaceRuntimeEnv($option, ($parentKey ? $parentKey.'_' : '').$key);
                continue;
            }

            $searchKey = 'SERVER_'.strtoupper(($parentKey ? $parentKey.'_' : '').$key);
            if (!empty($_ENV[$searchKey])) {
                $options[$key] = $parseType($_ENV[$searchKey]);
            }
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
