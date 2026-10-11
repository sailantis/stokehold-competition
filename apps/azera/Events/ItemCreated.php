<?php
/**
 * Event dispatched when a new item is created via FeatureService.
 */

namespace App\Azera\Events;

class ItemCreated
{
    public function __construct(
        public readonly int $id,
        public readonly string $title,
    ) {}

    /** @var array<int, array{id: int, title: string, at: string}> */
    private array $log = [];

    public function record(string $note): void
    {
        $this->log[] = ['id' => $this->id, 'title' => $this->title, 'at' => date('Y-m-d H:i:s') . ' — ' . $note];
    }

    /** @return array<int, array{id: int, title: string, at: string}> */
    public function log(): array
    {
        return $this->log;
    }
}