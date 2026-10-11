<?php
/**
 * Unit-of-Work demo service.
 *
 * Exercises the NEW ORM stack end-to-end (separate from the legacy
 * Model::save()/upsert() path the benchmark endpoints use):
 *
 *   Heap (identity map)  ->  EntityManager (diff + scheduling)  ->  flush()
 *   = one transaction with exactly the changed columns.
 *
 * The DbEventLog captures the SQL the EM emits so the endpoint can show
 * proof: a mutate + flush must produce ONE UPDATE listing ONLY the mutated
 * column, and a second flush with no changes must produce NO SQL at all
 * (the EM never writes clean entities).
 */

namespace App\Azera\Services;

use App\Azera\Models\Item;
use Azera\AppContext;
use Azera\Db\Event\QueryExecuted;
use Azera\Db\Event\TransactionCommitted;
use Azera\Db\Event\TransactionStarted;
use Azera\Orm\EntityManager;

class OrmDemoService
{
    public function __construct(
        private AppContext $ctx,
        private DbEventLog $log,
    ) {}

    /**
     * Load the sentinel item through the EntityManager (heap probe + Store
     * read -> hydrated MANAGED entity), mutate, persist + flush, and return
     * a report of what happened.
     */
    public function updateSentinelViaEm(): array
    {
        $this->log->clear();

        $sentinelId = 999999;
        $em         = $this->ctx->entityManager();

        // 1) Load — heap probe first, then one SELECT via the Store seam
        //    (no ResultSet, no FETCH_CLASS).
        $item = $em->find(Item::class, ['id' => $sentinelId]);

        $created = ($item === null);
        if ($created) {
            // First run on a fresh DB: seed the sentinel through the EM itself.
            $item = new Item();
            $item->id         = $sentinelId;
            $item->title      = 'EM Item ' . date('Y-m-d H:i:s');
            $item->created_at = date('Y-m-d H:i:s');
            $em->persist($item);
            $em->flush();
        }

        // 2) Mutate ONE field and persist: the EM must diff exactly this.
        $item->title = 'EM Item ' . date('Y-m-d H:i:s');
        $em->persist($item);

        // 3) Flush: one transaction, one UPDATE, only `title` in the SET.
        $em->flush();

        // 4) A second flush with nothing scheduled must be a no-op (no SQL).
        $sqlBeforeSecondFlush = $this->queryCount();
        $em->flush();

        $node = $em->heap()->findById(Item::class, ['id' => $sentinelId]);

        return [
            'created'                    => $created,
            'identity'                   => ['id' => $sentinelId],
            'title'                      => $item->title,
            'events'                     => $this->log->all(),
            'second_flush_emits_nothing' => $this->queryCount() === $sqlBeforeSecondFlush,
            'snapshot'                   => $node?->data,
        ];
    }

    /**
     * Load 3 items through the EntityManager and return their state.
     * Demonstrates the identity map: same PK loaded twice = same object.
     */
    public function hydrateViaStore(int $limit = 3): array
    {
        $em = $this->ctx->entityManager();

        $items = $em->findBy(Item::class, []);
        $items = \array_slice($items, 0, $limit);

        return [
            'count'    => \count($items),
            'first'    => isset($items[0]) ? $items[0]->id : null,
            'entities' => \array_map(fn($e) => $em->heap()->find($e)?->data, $items),
        ];
    }

    private function queryCount(): int
    {
        $n = 0;
        foreach ($this->log->all() as $e) {
            if (str_starts_with($e['type'], 'Query')) {
                $n++;
            }
        }
        return $n;
    }
}