<?php
/**
 * Azera REST API controller.
 *
 * Implements a minimal JSON REST API over the shared `items` table.
 * These endpoints are the "REST API" competition category — every
 * framework implements the same routes so the JSON serialization +
 * routing + controller overhead is compared apples-to-apples.
 *
 * Endpoints:
 *   GET    /api/items       — list items (JSON array)
 *   GET    /api/items/{id}  — fetch a single item (JSON object)
 *   POST   /api/items       — create an item (JSON with new id)
 */

namespace App\Azera\Controllers;

use App\Azera\Models\Item;
use Azera\Core\Controller;
use Azera\Http\Response;

class ApiController extends Controller
{
    /**
     * GET /api/items — list items as a JSON array.
     */
    public function indexAction(): Response
    {
        $items = Item::query()->orderBy('id', 'asc')->limit(20)->select();

        return Response::json($items->toArray());
    }

    /**
     * GET /api/items/{id} — fetch a single item as a JSON object.
     */
    public function showAction(int $id): Response
    {
        $item = Item::find($id);
        if ($item === null) {
            return Response::json(['error' => 'Not Found'], 404);
        }
        return Response::json($this->serialize($item));
    }

    /**
     * POST /api/items — create an item and return its id as JSON.
     */
    public function createAction(): Response
    {
        $item = Item::upsert([
            'id'         => 999998,
            'title'      => 'API Item ' . date('Y-m-d H:i:s'),
            'created_at' => date('Y-m-d H:i:s'),
        ]);

        return Response::json(['id' => $item->id]);
    }

    /**
     * Serialize a model to a plain array for JSON output.
     *
     * The Item model exposes public properties (id, title, created_at);
     * we read them directly to avoid coupling the API to any internal
     * attribute storage.
     */
    private function serialize(Item $item): array
    {
        return [
            'id'         => $item->id,
            'title'      => $item->title,
            'created_at' => $item->created_at,
        ];
    }
}