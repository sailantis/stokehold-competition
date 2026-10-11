<?php
/**
 * Azera benchmark Item model.
 *
 * Maps to the shared SQLite `items` table and is used by BenchController
 * for the /items endpoints.
 */

namespace App\Azera\Models;

use Azera\Orm\Model;

class Item extends Model
{
    /**
     * Explicit table name. The naming convention maps "Item" to "item"
     * (pluralization is off by default), so this override is REQUIRED to
     * target the shared `items` table. Both the Query builder (via
     * ModelResolver) and the ORM store seam (via Metadata) honor it.
     */
    public function source(): string
    {
        return 'items';
    }

    public int $id;

    public string $title;

    public string $created_at;
}