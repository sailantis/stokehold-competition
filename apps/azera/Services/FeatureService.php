<?php
/**
 * Feature demo service — exercises AOP #[Transactional] and #[Cache].
 *
 * This service is autowired (registered as a class string, not a factory)
 * so AppContext::build() generates an AOP proxy.  The #[Advised] attribute
 * on the class marks it for proxy generation; individual methods carry
 * #[Transactional] or #[Cache] to activate interception.
 */

namespace App\Azera\Services;

use Azera\Aop\Advised;
use Azera\Aop\Cache;
use Azera\Aop\Log;
use Azera\Aop\Retry;
use Azera\Aop\Transactional;
use Azera\AppContext;
use Azera\Db\Query;

#[Advised]
class FeatureService
{
    /** Fixed row used by every feature-demo write — the row count stays stable across benchmark runs. */
    public const FEATURE_SENTINEL_ID = 888800;

    public function __construct(
        private AppContext $ctx,
    ) {}

    /**
     * Create an item inside a transaction.
     *
     * The #[Transactional] interceptor wraps this method in a DB
     * transaction: begin before, commit on success, rollback on
     * exception.  No manual begin/commit/rollback needed.
     *
     * Writes the FIXED feature sentinel row (INSERT ... ON CONFLICT DO
     * UPDATE, upsert semantics) instead of a fresh INSERT per request —
     * the demo runs once per benchmark request, and an unbounded INSERT
     * would grow the shared table every request (the row count must stay
     * stable so COUNT-style reads measure constant work).
     */
    #[Transactional]
    public function createItemTransactional(string $title): int
    {
        $db = $this->ctx->dbManager()->getOrDefault('default');
        $db->query(
            'INSERT INTO items (id, title, created_at) VALUES (?, ?, ?)'
                . ' ON CONFLICT(id) DO UPDATE SET title = excluded.title, created_at = excluded.created_at',
            [self::FEATURE_SENTINEL_ID, $title, date('Y-m-d H:i:s')],
        );
        $id = self::FEATURE_SENTINEL_ID;

        // Dispatch an event — the listener will run synchronously
        // because we use EventDispatcher (PSR-14).
        $this->ctx->events()->dispatch(new \App\Azera\Events\ItemCreated($id, $title));

        return $id;
    }

    /**
     * Count items — result is cached for 10 seconds via #[Cache].
     *
     * The #[Cache] interceptor checks the cache before invoking the
     * method; on a miss it calls the method and stores the result.
     * The key is interpolated from the {segment} argument.
     *
     * The body is a real aggregate query and nothing else. An artificial
     * delay here (this used to usleep 50ms) is not a framework cost: it is
     * added to every app's cache-MISS row, and the deployment models differ
     * in whether they miss. php-fpm rebuilds the app context per request, so
     * every app always missed and paid it on every request, while a resident
     * RoadRunner worker hit and paid nothing — the delay measured the harness,
     * not the cache. On php-fpm it was 67% of azera's total-response-time
     * metric and it flattened the spread between frameworks from 15.3x to
     * 6.0x.
     */
    #[Cache(ttl: 10, key: 'item_count')]
    public function countItems(): int
    {
        $row = $this->ctx->dbManager()
            ->getOrDefault('default')
            ->selectRow('SELECT COUNT(*) AS c FROM items', null, \PDO::FETCH_ASSOC);

        return (int) ($row['c'] ?? 0);
    }

    /**
     * Count items WITHOUT the #[Cache] interceptor — the plain query path.
     *
     * Used by the Db Events demo, which must exercise a real query (and its
     * QueryExecuted / StatementPrepared events) on EVERY request instead of
     * a cache hit: routing it through countItems() would turn most calls into
     * no-op cache reads that fire no Db events.
     */
    public function countItemsQuery(): int
    {
        $row = $this->ctx->dbManager()
            ->getOrDefault('default')
            ->selectRow('SELECT COUNT(*) AS c FROM items', null, \PDO::FETCH_ASSOC);

        return (int) ($row['c'] ?? 0);
    }
    /**
     * Internal hook used by the cache endpoint to inspect whether the
     * #[Cache] interceptor actually hit without changing the public method
     * signature used by the benchmark.
     */
    public function countItemsHit(): bool
    {
        $cache = $this->ctx->get('App\\Azera\\Cache\\ArrayCache');
        return $cache !== null && $cache->has('item_count');
    }
    /**
     * Log a message via the #[Log] AOP advice.
     *
     * The LogInterceptor logs method entry, exit (with duration), and any
     * exception.  The MemoryLogger registered in Bootstrap captures the
     * entries so the controller can show them.
     */
    #[Log(level: 'info', logArgs: true)]
    public function logSomething(string $message): string
    {
        return "logged: {$message}";
    }

    /**
     * Retry a flaky operation via the #[Retry] AOP advice.
     *
     * The RetryInterceptor retries the method up to `times` attempts
     * (including the first).  This method fails on the first two calls
     * and succeeds on the third, so the interceptor's retry loop is
     * exercised and the final result is returned.
     */
    #[Retry(times: 3, backoff: 0)]
    public function flakyOperation(): string
    {
        static $attempts = 0;
        $attempts++;

        if ($attempts < 3) {
            throw new \RuntimeException("flaky failure (attempt {$attempts})");
        }

        return "succeeded on attempt {$attempts}";
    }
}