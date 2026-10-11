<?php
/**
 * In-memory PSR-3 logger.
 *
 * Records every log message into an array so the demo controller can
 * surface what the #[Log] AOP interceptor wrote.  Swappable with any
 * real PSR-3 logger (e.g. Monolog) — the AOP interceptors only depend
 * on the LoggerInterface.
 */

namespace App\Azera\Services;

use Azera\Lifecycle\RequestScoped;
use Psr\Log\LoggerInterface;

class MemoryLogger implements LoggerInterface, RequestScoped
{
    /** @var array<int, array{level: string, message: string, context: array}> */
    private array $entries = [];

    public function emergency(string|\Stringable $message, array $context = []): void
    {
        $this->record('emergency', $message, $context);
    }

    public function alert(string|\Stringable $message, array $context = []): void
    {
        $this->record('alert', $message, $context);
    }

    public function critical(string|\Stringable $message, array $context = []): void
    {
        $this->record('critical', $message, $context);
    }

    public function error(string|\Stringable $message, array $context = []): void
    {
        $this->record('error', $message, $context);
    }

    public function warning(string|\Stringable $message, array $context = []): void
    {
        $this->record('warning', $message, $context);
    }

    public function notice(string|\Stringable $message, array $context = []): void
    {
        $this->record('notice', $message, $context);
    }

    public function info(string|\Stringable $message, array $context = []): void
    {
        $this->record('info', $message, $context);
    }

    public function debug(string|\Stringable $message, array $context = []): void
    {
        $this->record('debug', $message, $context);
    }

    public function log($level, string|\Stringable $message, array $context = []): void
    {
        $this->record((string) $level, $message, $context);
    }

    private function record(string $level, string|\Stringable $message, array $context): void
    {
        $this->entries[] = [
            'level'   => $level,
            'message' => (string) $message,
            'context' => $context,
        ];
    }

    /** @return array<int, array{level: string, message: string, context: array}> */
    public function entries(): array
    {
        return $this->entries;
    }

    public function clear(): void
    {
        $this->entries = [];
    }

    /**
     * Request-scoped hook: wipe captured log messages between requests in
     * persistent workers (same contract as DbEventLog).
     */
    public function resetState(): void
    {
        $this->entries = [];
    }
}