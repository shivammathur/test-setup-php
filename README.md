# Symfony Swoole Bundle

[![App Tester](https://github.com/cesurapp/swoole-bundle/actions/workflows/testing.yaml/badge.svg)](https://github.com/cesurapp/swoole-bundle/actions/workflows/testing.yaml)
[![Software License](https://img.shields.io/badge/license-MIT-brightgreen.svg?logo=Unlicense)](LICENSE.md)

Built-in Swoole http server, background jobs (Task), scheduled task (Cron) worker are available.
Failed jobs are saved in the database to be retried. Each server has built-in background task worker.
Scheduled tasks run simultaneously on all servers. It is not possible for tasks to run at the same time as locking is used.

### Install 
Required Symfony 7
```bash
composer req cesurapp/swoole-bundle
```

__Edit: public/index.php__
```php
...
require_once dirname(__DIR__).'/vendor/cesurapp/swoole-bundle/src/Runtime/entrypoint.php';
require_once dirname(__DIR__).'/vendor/autoload_runtime.php';
...
```

__Configuration:__
```shell
# config/packages/swoole.yaml
swoole:
  entrypoint: public/index.php
  watch_dir: /config,/src,/templates
  watch_extension: *.php,*.yaml,*.yml,*.twig
  replace_http_client: true # Replate Symfony HTTP Client to Swoole Client 
  cron_worker: true # Enable Cron Worker Service
  task_worker: true # Enable Task Worker Service
  failed_task_retry: '@EveryMinute10'
  failed_task_attempt: 2 # Failed Task Retry Count
```

__Server Environment: .env__
```dotenv
SERVER_WORKER_CRON=true # Run Cron Worker
SERVER_WORKER_TASK=true # Run Task Worker
SERVER_HTTP_HOST=127.0.0.1
SERVER_HTTP_PORT=9090
SERVER_HTTP_CACHE_TABLE_SIZE=750 # Cache Table Row Count
SERVER_HTTP_CACHE_TABLE_COLUMN_LENGTH=25000
SERVER_HTTP_SETTINGS_WORKER_NUM=2
SERVER_HTTP_SETTINGS_TASK_WORKER_NUM=1
SERVER_HTTP_SETTINGS_LOG_LEVEL=4 # Details Openswoole\Constant LOG_LEVEL
```

### Server Commands
```shell
# Cron Commands
bin/console cron:list     # List cron jobs

# Server Commands
bin/console server:start  # Start http,cron,queue server
bin/console server:stop   # Stop http,cron,queue server
bin/console server:status # Status http,cron,queue server
bin/console server:watch  # Start http,cron,queue server for development mode (file watcher enabled)

# Task|Job Commands
bin/console task:list           # List registered tasks
bin/console task:failed:clear   # Clear all failed task
bin/console task:failed:retry   # Forced send all failed tasks to swoole task worker
bin/console task:failed:view    # Lists failed tasks
```

### Create Cron Job
You can use cron expression for scheduled tasks, or you can use predefined expressions.

```php
/**
 * Predefined Scheduling
 *
 * '@yearly'    => '0 0 1 1 *',
 * '@annually'  => '0 0 1 1 *',
 * '@monthly'   => '0 0 1 * *',
 * '@weekly'    => '0 0 * * 0',
 * '@daily'     => '0 0 * * *',
 * '@hourly'    => '0 * * * *',
 * '@EveryMinute'    => 'w* * * * *',
 * "@EveryMinute5'  => '*\/5 * * * *',
 * '@EveryMinute10'  => '*\/10 * * * *',
 * '@EveryMinute15'  => '*\/15 * * * *',
 * '@EveryMinute30'  => '*\/30 * * * *',```
 */
class ExampleJob implements \Cesurapp\SwooleBundle\Cron\AbstractCronJob {
    /**
     * @see AbstractCronJob
     */
    public string $TIME = '@EveryMinute10';

    /**
     * Cron is Enable|Disable.
     */
    public bool $ENABLE = true;
    
    /**
     * Cron Context 
     */
    public function __invoke(): void {
    
    }
}
```

### Create Task (Background Job or Queue)
Data passed to jobs must be of type string, int, bool, array, objects cannot be serialized.

Create:
```php
class ExampleTask implements \Cesurapp\SwooleBundle\Task\TaskInterface {
    public function __invoke(object|string $data = null): void {
        var_dump(
            $data['name'],
            $data['invoke']
        );
    }
}
```

Handle Task:
```php
public function hello(\Cesurapp\SwooleBundle\Task\TaskHandler $taskHandler) {
    $taskHandler->dispatch(ExampleTask::class, [
        'name' => 'Test',
        'invoke' => 'Data'
    ]);
}
```