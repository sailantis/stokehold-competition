<?php
/**
 * Listener for framework Db events.
 *
 * Registered against the PSR-14 dispatcher for the concrete Db event
 * classes (QueryExecuted, StatementPrepared, TransactionStarted,
 * TransactionCommitted).  Because EventDispatcher resolves listeners for
 * parent classes and interfaces too, this single __invoke() handler can
 * be registered once per concrete event class and still receive every
 * DatabaseEvent subtype.
 */

namespace App\Azera\Events\Listener;

use App\Azera\Services\DbEventLog;
use Azera\Db\Event\QueryExecuted;
use Azera\Db\Event\StatementPrepared;
use Azera\Db\Event\TransactionCommitted;
use Azera\Db\Event\TransactionStarted;

class DatabaseEventListener
{
    public function __construct(
        private DbEventLog $log,
    ) {}

    public function __invoke(object $event): void
    {
        if ($event instanceof QueryExecuted) {
            $this->log->record('query', [
                'sql'         => $event->sql,
                'duration_ms' => round($event->durationMs, 2),
            ]);
        } elseif ($event instanceof StatementPrepared) {
            $this->log->record('prepared', ['sql' => $event->sql]);
        } elseif ($event instanceof TransactionStarted) {
            $this->log->record('tx_started', ['level' => $event->level]);
        } elseif ($event instanceof TransactionCommitted) {
            $this->log->record('tx_committed', ['level' => $event->level]);
        }
    }
}