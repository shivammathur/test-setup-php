<?php

namespace Cesurapp\SwooleBundle\Cron;

use Symfony\Bundle\FrameworkBundle\DataCollector\TemplateAwareDataCollectorInterface;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\DataCollector\DataCollector;

class CronDataCollector extends DataCollector implements TemplateAwareDataCollectorInterface
{
    public function __construct(private readonly CronWorker $cronWorker)
    {
    }

    public function collect(Request $request, Response $response, ?\Throwable $exception = null): void
    {
        $crons = iterator_to_array($this->cronWorker->getAll());
        $this->data['count'] = count($crons);
        $this->data['crons'] = array_map(static fn ($cron) => [
            'class' => explode('Ghost', explode('\\', get_class($cron))[1] ?? '')[0] ?? '',
            'time' => $cron->TIME,
            'enable' => $cron->ENABLE,
            'isDue' => $cron->isDue,
            'next' => $cron->next->format('Y-m-d H:i:s'),
        ], $crons);
    }

    public function getCount(): int
    {
        return $this->data['count'] ?? 0;
    }

    public function getCrons(): ?array
    {
        return $this->data['crons'] ?? null;
    }

    public function getName(): string
    {
        return static::class;
    }

    public static function getTemplate(): ?string
    {
        return 'cron_data_collector.html.twig';
    }
}
