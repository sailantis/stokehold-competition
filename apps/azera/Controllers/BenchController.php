<?php
/**
 * Azera benchmark controller.
 *
 * Implements the 4 benchmark endpoints using the Azera router/dispatcher,
 * ClarityEngine templates, and the Item model over SQLite.
 */

namespace App\Azera\Controllers;

use App\Azera\Models\Item;
use App\Azera\Services\OrmDemoService;
use Azera\AppContext;
use Azera\Core\Controller;
use Azera\Db\Query;
use Azera\Http\Response;

class BenchController extends Controller
{
    /**
     * GET / — welcome page via Clarity template (no DB, just routing + middleware + template render).
     */
    public function indexAction(): Response
    {
        $html = $this->view()->render('home.welcome');
        return Response::html($html);
    }

    /**
     * GET /items — list items via model with pagination + render list template.
     *
     * Accepts ?page=N query parameter (defaults to 1).  Shows 20 items
     * per page with prev/next navigation links.
     */
    public function listAction(): Response
    {
        $page     = (int) AppContext::instance()->request()->query('page', 1);
        $pageSize = 20;

        $paginator = Item::query()->paginate($page, $pageSize);
        $items     = $paginator->entities();

        $html = $this->view()->render('items.list', [
            'baseUrl'    => '/items',
            'items'      => $items,
            'pagination' => [
                'currentPage'  => $paginator->currentPage(),
                'lastPage'     => $paginator->lastPage(),
                'previousPage' => $paginator->previousPage(),
                'nextPage'     => $paginator->nextPage(),
                'totalItems'   => $paginator->totalItems(),
                'firstItem'    => $paginator->firstItem(),
                'lastItem'     => $paginator->lastItem(),
                'hasPrevious'  => $paginator->hasPrevious(),
                'hasNext'      => $paginator->hasNext(),
            ],
        ]);
        return Response::html($html);
    }

    /**
     * GET /items/{id} — find a single item by id + render single template.
     */
    public function showAction(int $id): Response
    {
        $item = Item::find($id);
        if ($item === null) {
            return Response::text('Not Found', 404);
        }
        $html = $this->view()->render('items.show', [
            'item' => $item,
        ]);
        return Response::html($html);
    }

    /**
     * POST /items — upsert a sentinel item via Model ORM, render the item
     * detail template with a flash message.
     *
     * Uses Item::upsert() (INSERT ... ON CONFLICT DO UPDATE) with a fixed
     * sentinel ID (999999) so the row count stays stable across benchmark
     * runs.  This exercises the atomic write path: model instantiation and
     * the query builder's upsert compilation.
     *
     * Unlike POST /api/items (pure JSON), this renders the show template
     * with an inline flash banner ("created" on INSERT, "updated" after).
     * The exists() probe adds the same SELECT the other frameworks' write
     * paths pay, keeping the SELECT + write + render sequence comparable.
     */
    public function createAction(): Response
    {
        $existed = Item::exists(['id' => 999999]);

        $item = Item::upsert([
            'id'         => 999999,
            'title'      => 'Created Item ' . date('Y-m-d H:i:s'),
            'created_at' => date('Y-m-d H:i:s'),
        ]);

        $html = $this->view()->render('items.show', [
            'item'  => $item,
            'flash' => 'Item #' . $item->id . ($existed ? ' updated' : ' created') . ' ✓',
        ]);

        return Response::html($html);
    }

    /**
     * GET /items-orm — list items via the NEW ORM stack (raw rows -> Heap
     * entities) with the same pagination + template as GET /items.
     *
     * This is the hydration comparison endpoint: identical page of 20 rows
     * and identical template render as the legacy path, but hydration runs
     * through the UNIFIED query builder (Item::query()->entities()):
     * raw rows + FastHydrator + request-scoped Heap identity map. Same
     * COUNT + SELECT sequence as the legacy paginator keeps the SQL work
     * comparable.
     */
    public function listOrmAction(): Response
    {
        $page     = (int) AppContext::instance()->request()->query('page', 1);
        $pageSize = 20;

        $total = Item::query()->count();
        $pages = (int) max(1, ceil($total / $pageSize));
        $page  = max(1, min($page, $pages));

        // Unified builder: criteria (where/orderBy/limit) compile from the
        // same Query the raw and QB paths use; entities() hydrates via the
        // ORM (FastHydrator + Heap). No raw SQL, no separate criteria class.
        $items = Item::query()
            ->orderBy('id')
            ->limit($pageSize, ($page - 1) * $pageSize)
            ->entities();

        $html = $this->view()->render('items.list', [
            'baseUrl'    => '/items-orm',
            'items'      => $items,
            'pagination' => [
                'currentPage'  => $page,
                'lastPage'     => $pages,
                'previousPage' => max(1, $page - 1),
                'nextPage'     => min($pages, $page + 1),
                'totalItems'   => $total,
                'firstItem'    => ($page - 1) * $pageSize + 1,
                'lastItem'     => ($page - 1) * $pageSize + count($items),
                'hasPrevious'  => $page > 1,
                'hasNext'      => $page < $pages,
            ],
        ]);
        return Response::html($html);
    }

    /**
     * GET /items-orm/{id} — single item via the NEW ORM stack.
     * Unified builder terminal (firstEntity) — heap-tracked entity from
     * metadata-driven hydration on the request-scoped identity map.
     */
    public function showOrmAction(int $id): Response
    {
        $item = Item::query()
            ->where('id', '=', $id)
            ->firstEntity();
        if ($item === null) {
            return Response::text('Not Found', 404);
        }

        $html = $this->view()->render('items.show', [
            'item' => $item,
        ]);
        return Response::html($html);
    }

    /**
     * POST /items-orm — write via the canonical FACADE surface (Item::find()
     * + Model::save()) which delegates to the EntityManager: read (FETCH_CLASS
     * or heap hit) → mutate → save() → adopt + persist + flush (diff UPDATE
     * of changed cols only).
     *
     * Same sentinel (999999) + flash render as POST /items, so legacy
     * upsert vs the facade-over-EM path isolates the write difference.
     * SQL-identical to an EM-direct find → persist → flush (trace-verified).
     */
    public function createOrmAction(): Response
    {
        $item    = Item::find(999999);
        $existed = ($item !== null);

        if ($item === null) {
            $item = new Item();
            $item->id         = 999999;
            $item->created_at = date('Y-m-d H:i:s');
        }

        // Microsecond-unique title — guarantees a real diff every request
        // (date() has second resolution; repeated values would diff nothing
        // and correctly skip the write).
        $item->title = 'Created Item ' . date('Y-m-d H:i:s')
            . ' #' . substr(str_replace('.', '', (string) microtime(true)), -6);

        $item->save();

        $html = $this->view()->render('items.show', [
            'item'  => $item,
            'flash' => 'Item #' . $item->id . ($existed ? ' updated' : ' created') . ' ✓',
        ]);

        return Response::html($html);
    }

    /* -------------------------------------------------------------
     *  QUERY BUILDER ENDPOINTS (no ORM hydration)
     * ----------------------------------------------------- */

    /**
     * GET /items-qb — list items via raw Query Builder with pagination.
     *
     * Same as GET /items but bypasses model hydration — fetches rows
     * directly as arrays via the query builder.  Compares ORM hydration
     * overhead vs raw row fetching.
     */
    public function listQbAction(): Response
    {
        $page     = (int) $this->request()->query('page', 1);
        $pageSize = 20;

        // Table-level Query Builder (Query::raw() = literal table names, no
        // model mapping) — same approach as CI4 table('items') and Spiral's
        // db->select()->from('items'). Paginator returns plain arrays.
        $paginator = Query::raw()->table('items')->paginate($page, $pageSize);
        $items     = $paginator->objects();

        $html = $this->view()->render('items.list', [
            'baseUrl'    => '/items-qb',
            'items'      => $items,
            'pagination' => [
                'currentPage'  => $paginator->currentPage(),
                'lastPage'     => $paginator->lastPage(),
                'previousPage' => $paginator->previousPage(),
                'nextPage'     => $paginator->nextPage(),
                'totalItems'   => $paginator->totalItems(),
                'firstItem'    => $paginator->firstItem(),
                'lastItem'     => $paginator->lastItem(),
                'hasPrevious'  => $paginator->hasPrevious(),
                'hasNext'      => $paginator->hasNext(),
            ],
        ]);
        return Response::html($html);
    }

    /**
     * GET /items-qb/{id} — find a single item by id via raw Query Builder.
     *
     * Same as GET /items/{id} but uses the query builder directly instead
     * of Item::find().  No model instantiation or hydration.
     */
    public function showQbAction(int $id): Response
    {
        // Table-level query builder — returns a stdClass, not a model.
        $row = Query::raw()->table('items')->where('id', $id)->select()->fetchObject();
        if ($row === null) {
            return Response::text('Not Found', 404);
        }
        $html = $this->view()->render('items.show', [
            'item' => $row,
        ]);
        return Response::html($html);
    }

    /**
     * POST /items-qb — upsert a sentinel item via the table-level Query
     * Builder (Query::raw() = literal table names, no model mapping or
     * hydration). POST /items (ORM) vs POST /items-qb (QB) gives a clean
     * ORM-vs-builder write comparison on the same method.
     *
     * Same render treatment as POST /items: detail template + flash, so
     * the two HTML write endpoints stay symmetric (POST /api/items remains
     * the pure JSON write measurement).
     */
    public function createQbAction(): Response
    {
        $title      = 'Created Item ' . date('Y-m-d H:i:s');
        $created_at = date('Y-m-d H:i:s');

        $existed = Query::raw()->table('items')->where('id', 999997)->exists();

        Query::raw()
            ->table('items')
            ->conflict(['id'])
            ->upsert([
                'id'         => 999997,
                'title'      => $title,
                'created_at' => $created_at,
            ]);

        $html = $this->view()->render('items.show', [
            'item' => (object) [
                'id'         => 999997,
                'title'      => $title,
                'created_at' => $created_at,
            ],
            'flash' => 'Item #999997' . ($existed ? ' updated' : ' created') . ' ✓',
        ]);

        return Response::html($html);
    }
}