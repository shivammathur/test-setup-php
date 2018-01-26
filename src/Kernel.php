<?php

/**
 * This file is part of Laravel Zero.
 *
 * (c) Nuno Maduro <enunomaduro@gmail.com>
 *
 *  For the full copyright and license information, please view the LICENSE
 *  file that was distributed with this source code.
 */

namespace LaravelZero\Framework;

use Illuminate\Console\Application as Artisan;
use Illuminate\Foundation\Console\Kernel as BaseKernel;

/**
 * This is the Laravel Zero Kernel implementation.
 */
class Kernel extends BaseKernel
{
    /**
     * The application's development commands.
     *
     * @var string[]
     */
    protected $developmentCommands = [
        Commands\App\Builder::class,
        Commands\App\Renamer::class,
        Commands\App\CommandMaker::class,
        Commands\Component\Illuminate\Log\Installer::class,
        Commands\Component\Vlucas\Phpdotenv\Installer::class,
        Commands\Component\Illuminate\Database\Installer::class,
    ];

    /**
     * The application's bootstrap classes.
     *
     * @var string[]
     */
    protected $bootstrappers = [
        \LaravelZero\Framework\Bootstrap\LoadEnvironmentVariables::class,
        \LaravelZero\Framework\Bootstrap\Constants::class,
        \LaravelZero\Framework\Bootstrap\LoadConfiguration::class,
        \Illuminate\Foundation\Bootstrap\HandleExceptions::class,
        \Illuminate\Foundation\Bootstrap\RegisterFacades::class,
        \LaravelZero\Framework\Bootstrap\RegisterProviders::class,
        \Illuminate\Foundation\Bootstrap\BootProviders::class,
    ];

    /**
     * Gets the application name.
     *
     * @return string
     */
    public function getName(): string
    {
        return $this->getArtisan()->getName();
    }

    /**
     * Register the commands for the application.
     *
     * @return void
     */
    protected function commands(): void
    {
        $config = $this->app['config'];

        /**
         * Loads commands paths.
         */
        $this->load($config->get('app.commands-paths', $this->app->path('Commands')));

        /**
         * Loads configurated commands.
         */
        $commands = collect($config->get('app.commands', []))->push($config->get('app.default-command'));

        /**
         * Loads development commands.
         */
        if ($this->app->environment() !== 'production') {
            $commands = $commands->merge($this->developmentCommands);
        }

        /**
         * Loads scheduler commands.
         */
        if ($config->get('app.with-scheduler')) {
            $commands = $commands->merge(
                [
                    \Illuminate\Console\Scheduling\ScheduleRunCommand::class,
                    \Illuminate\Console\Scheduling\ScheduleFinishCommand::class,
                ]
            );
        }

        /**
         * Registers a bootstrap callback on the artisan console application
         * in order to call the schedule method on each Laravel Zero
         * command class.
         */
        Artisan::starting(
            function ($artisan) use ($commands) {
                $artisan->resolveCommands($commands->toArray());

                collect($artisan->all())->each(
                    function ($command) {
                        if ($command instanceof Commands\Command) {
                            $this->app->call([$command, 'schedule']);
                        }
                    }
                );
            }
        );
    }
}
