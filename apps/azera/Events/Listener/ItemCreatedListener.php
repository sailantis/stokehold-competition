<?php
/**
 * Listener for ItemCreated events.
 *
 * Demonstrates PSR-14 event handling: the listener is registered in
 * Bootstrap::registerEnterpriseServices() and invoked synchronously
 * by EventDispatcher when ItemCreated is dispatched.
 */

namespace App\Azera\Events\Listener;

use App\Azera\Events\ItemCreated;
use Psr\Log\LoggerInterface;

class ItemCreatedListener
{
    public function __construct(
        private LoggerInterface $logger,
    ) {}

    public function __invoke(ItemCreated $event): void
    {
        // Log via PSR-3 (NullLogger by default — swap to Monolog to see output)
        $this->logger->info('Item created', ['id' => $event->id, 'title' => $event->title]);

        // Stamp the event so the controller can show the listener ran
        $event->record('ItemCreatedListener processed');
    }
}