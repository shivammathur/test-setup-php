<?php

namespace Cesurapp\SwooleBundle\Runtime\SwooleServer;

use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;
use Symfony\Component\HttpFoundation\BinaryFileResponse;
use Symfony\Component\HttpFoundation\HeaderBag;
use Symfony\Component\HttpFoundation\Request as SymfonyRequest;
use Symfony\Component\HttpFoundation\Response as SymfonyResponse;
use Symfony\Component\HttpFoundation\StreamedResponse;
use Symfony\Component\HttpKernel\HttpKernelInterface;
use Symfony\Component\HttpKernel\TerminableInterface;

class HttpServer extends Server
{
    public function __construct(private readonly HttpKernelInterface $application, private readonly array $options)
    {
        parent::__construct(
            $this->options['http']['host'],
            (int) $this->options['http']['port'],
            (int) $this->options['http']['mode'],
            (int) $this->options['http']['sock_type']
        );
        $this->set($this->options['http']['settings']);

        // Manager Start
        $this->on('request', [$this, 'onRequest']);
        $this->on('managerstart', [$this, 'onStart']);

        $GLOBALS['httpServer'] = $this;
    }

    /**
     * Handle Request.
     */
    public function onRequest(Request $request, Response $response): void
    {
        $sfRequest = $this->toSymfonyRequest($request);
        $sfResponse = $this->application->handle($sfRequest);
        $this->toSwooleResponse($sfResponse, $response);

        // Application Terminate
        if ($this->application instanceof TerminableInterface) {
            $this->application->terminate($sfRequest, $sfResponse);
        }
    }

    private function toSymfonyRequest(Request $request): SymfonyRequest
    {
        $sfRequest = new SymfonyRequest(
            $request->get ?? [],
            $request->post ?? [],
            [],
            $request->cookie ?? [],
            $request->files ?? [],
            array_change_key_case($request->server ?? [], CASE_UPPER),
            $request->rawContent()
        );
        $sfRequest->headers = new HeaderBag($request->header ?? []);

        return $sfRequest;
    }

    private function toSwooleResponse(SymfonyResponse $sfResponse, Response $response): void
    {
        // Set Header
        $response->status($sfResponse->getStatusCode());
        foreach ($sfResponse->headers->all() as $name => $values) {
            $response->header($name, !is_array($values) ? (string) $values : implode(',', $values));
        }

        switch (true) {
            case $sfResponse instanceof BinaryFileResponse && $sfResponse->headers->has('Content-Range'):
            case $sfResponse instanceof StreamedResponse:
                ob_start(static function ($buffer) use ($response) {
                    $response->write($buffer);

                    return '';
                });
                $sfResponse->sendContent();
                ob_end_clean();
                $response->end();
                break;
            case $sfResponse instanceof BinaryFileResponse:
                $response->sendfile($sfResponse->getFile()->getPathname());
                break;
            default:
                $response->end($sfResponse->getContent());
        }
    }

    /**
     * Handle Server Start Event.
     */
    public function onStart(HttpServer $server): void
    {
        // Server Information
        $watch = $this->options['worker']['watch'] ?? 1;
        if ($watch < 2) {
            echo 'Swoole Server Information'.PHP_EOL;
            echo '------------------------------'.PHP_EOL;
            echo 'Host         => '.$this->options['http']['host'].':'.$this->options['http']['port'].PHP_EOL;
            echo 'Tcp Host     => 127.0.0.1:9502'.PHP_EOL;
            echo 'Http Worker  => True'.sprintf(' (%s Worker)', $this->options['http']['settings']['worker_num']).PHP_EOL;
            echo 'Task Worker  => '.($this->options['worker']['task'] ? 'True' : 'False').sprintf(' (%s Worker)', $this->options['http']['settings']['task_worker_num']).PHP_EOL;
            echo 'Cron Worker  => '.($this->options['worker']['cron'] ? 'True' : 'False').PHP_EOL;
            echo 'Log Level    => '.match ((int) $this->options['http']['settings']['log_level']) {
                0 => 'LOG_DEBUG',
                1 => 'LOG_TRACE',
                2 => 'LOG_INFO',
                3 => 'LOG_NOTICE',
                4 => 'LOG_WARNING',
                5 => 'LOG_ERROR',
                6 => 'LOG_NONE',
                default => '-'
            }.PHP_EOL;
            echo 'Log File     => '.($this->options['http']['settings']['log_file'] ?? 'STDOUT').PHP_EOL;
            echo 'Max Request  => '.($this->options['http']['settings']['max_request'] ?? 0).' Req'.PHP_EOL;
            echo 'Task Max Req => '.($this->options['http']['settings']['task_max_request'] ?? 0).' Req'.PHP_EOL;
            echo 'Max WaitTime => '.($this->options['http']['settings']['max_wait_time'] ?? 30).' sec'.PHP_EOL;
            echo PHP_EOL;

            echo 'App Information'.PHP_EOL;
            echo '------------------------------'.PHP_EOL;
            echo 'Debug        => '.($this->options['debug'] ? 'True' : 'False').PHP_EOL;
            echo 'Environment  => '.strtoupper($this->options['env']).PHP_EOL;
            echo isset($_ENV['APP_LOG_LEVEL']) ? 'Log Level    => '.ucfirst($_ENV['APP_LOG_LEVEL']).PHP_EOL : '';
            echo isset($_ENV['APP_LOG_FILE']) ? 'Log File     => '.$_ENV['APP_LOG_FILE'].PHP_EOL : '';
            echo PHP_EOL;
        }
    }
}
