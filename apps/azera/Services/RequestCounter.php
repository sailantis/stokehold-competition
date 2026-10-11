<?php
/**
 * Request-scoped counter service.
 *
 * Implements {@see \Azera\Lifecycle\RequestScoped} so that in a long-lived
 * worker (RoadRunner / Swoole) its per-request state is reset automatically
 * by {@see \Azera\AppContext::clearRequestScope()} after each request.
 *
 * The demo controller increments the counter and reads it back; calling
 * clearRequestScope() between requests proves the state does not leak.
 */

namespace App\Azera\Services;

use Azera\Lifecycle\RequestScoped;

class RequestCounter implements RequestScoped
{
    private int $count = 0;

    public function increment(): int
    {
        return ++$this->count;
    }

    public function count(): int
    {
        return $this->count;
    }

    public function resetState(): void
    {
        $this->count = 0;
    }
}