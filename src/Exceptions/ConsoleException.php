<?php

/**
 * This file is part of Laravel Zero.
 *
 * (c) Nuno Maduro <enunomaduro@gmail.com>
 *
 *  For the full copyright and license information, please view the LICENSE
 *  file that was distributed with this source code.
 */

namespace LaravelZero\Framework\Exceptions;

use Exception;
use LaravelZero\Framework\Contracts\Exceptions\ConsoleException as ConsoleExceptionContract;

/**
 * This is the Laravel Zero Framework Console Exception Implementation.
 */
class ConsoleException extends Exception implements ConsoleExceptionContract
{
    /**
     * The exit code.
     *
     * @var int
     */
    private $exitCode;

    /**
     * The headers.
     *
     * @var array
     */
    private $headers;

    /**
     * ConsoleException constructor.
     *
     * @param int $exitCode
     * @param string|null $message
     * @param \Exception|null $previous
     * @param array $headers
     * @param int code
     */
    public function __construct(
        int $exitCode, string $message = null, array $headers = [], \Exception $previous = null, ?int $code = 0
    ) {
        $this->exitCode = $exitCode;
        $this->headers = $headers;

        parent::__construct($message, $code, $previous);
    }

    /**
     * {@inheritdoc}
     */
    public function getExitCode(): int
    {
        return $this->exitCode;
    }

    /**
     * {@inheritdoc}
     */
    public function getHeaders(): array
    {
        return $this->headers;
    }

    /**
     * {@inheritdoc}
     */
    public function setHeaders(array $headers): ConsoleExceptionContract
    {
        $this->headers = $headers;

        return $this;
    }
}
