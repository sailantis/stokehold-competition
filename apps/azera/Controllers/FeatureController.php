<?php
/**
 * Feature demo controller — exercises all new enterprise subsystems.
 *
 * Endpoints:
 *   GET  /features           — overview page
 *   GET  /features/aop        — #[Transactional] AOP demo (insert in a transaction)
 *   GET  /features/cache      — #[Cache] AOP demo (cached DB count)
 *   GET  /features/log        — #[Log] AOP demo (method entry/exit logging)
 *   GET  /features/retry      — #[Retry] AOP demo (retry a flaky method)
 *   GET  /features/db-events  — Db event pipeline demo
 *   GET  /features/validation — Validator demo (valid + invalid payloads)
 *   GET  /features/config     — Config dot-notation demo
 *   GET  /features/request-scoped — RequestScoped lifecycle demo
 *   GET  /features/pipeline   — direct (explicit) AOP Pipeline demo
 *   GET  /features/events     — PSR-14 event dispatch + listener demo
 *   GET  /features/rate-limit — RateLimiter demo (max 5 requests / 60s)
 *   GET  /features/security   — Hasher + CSRF token demo
 *   POST /features/security   — CSRF-protected POST demo
 */

namespace App\Azera\Controllers;

use App\Azera\Events\ItemCreated;
use App\Azera\Services\DbEventLog;
use App\Azera\Services\FeatureService;
use App\Azera\Services\MemoryLogger;
use App\Azera\Services\RequestCounter;
use Azera\Aop\LogInterceptor;
use Azera\Aop\RetryInterceptor;
use Azera\AppContext;
use Azera\Core\Controller;
use Azera\Http\Response;
use Azera\Security\CsrfMiddleware;
use Azera\Security\Hasher;
use Azera\Security\RateLimiter;
use Azera\Validation\Validator;

class FeatureController extends Controller
{
    /**
     * GET /features — overview page listing all feature demos.
     */
    public function indexAction(): Response
    {
        $html = $this->view()->render('features.index', [
            'features' => [
                ['url' => '/features/aop', 'title' => 'AOP #[Transactional]', 'desc' => 'Insert a row inside an AOP-managed DB transaction'],
                ['url' => '/features/cache', 'title' => 'AOP #[Cache]', 'desc' => 'Cache a method result for 10 seconds via #[Cache] attribute'],
                ['url' => '/features/log', 'title' => 'AOP #[Log]', 'desc' => 'Log method entry/exit/duration via the #[Log] advice'],
                ['url' => '/features/retry', 'title' => 'AOP #[Retry]', 'desc' => 'Retry a failing method up to N times via the #[Retry] advice'],
                ['url' => '/features/db-events', 'title' => 'Db Events', 'desc' => 'Observe QueryExecuted / StatementPrepared / Transaction events'],
                ['url' => '/features/validation', 'title' => 'Validation', 'desc' => 'Validate and coerce input via the Validator'],
                ['url' => '/features/config', 'title' => 'Config', 'desc' => 'Dot-notation access to a nested config array'],
                ['url' => '/features/request-scoped', 'title' => 'RequestScoped', 'desc' => 'Reset per-request state via clearRequestScope()'],
                ['url' => '/features/pipeline', 'title' => 'AOP Pipeline (direct)', 'desc' => 'Explicit interceptor pipeline — no proxy generation'],
                ['url' => '/features/events', 'title' => 'PSR-14 Events', 'desc' => 'Dispatch an event and show listener output'],
                ['url' => '/features/rate-limit', 'title' => 'Rate Limiter', 'desc' => 'Allow max 5 requests per 60 seconds'],
                ['url' => '/features/security', 'title' => 'Security (Hasher + CSRF)', 'desc' => 'Password hashing and CSRF token protection'],
            ],
        ]);
        return Response::html($html);
    }

    /**
     * GET /features/aop — create an item via #[Transactional] AOP.
     */
    public function aopAction(FeatureService $service): Response
    {
        $title = 'AOP Item ' . date('Y-m-d H:i:s') . ' #' . random_int(1000, 9999);
        $id    = $service->createItemTransactional($title);

        return Response::json([
            'feature'     => 'AOP #[Transactional]',
            'description' => 'Inserted a row inside a DB transaction managed by the #[Transactional] interceptor — no manual begin/commit/rollback.',
            'new_id'      => $id,
            'title'       => $title,
            'proxy_class' => $service::class,
            'is_proxied'  => $service::class !== FeatureService::class,
        ]);
    }

    /**
     * GET /features/cache — demonstrate #[Cache] AOP caching.
     */
    public function cacheAction(FeatureService $service): Response
    {
        $start     = microtime(true);
        $count     = $service->countItems();
        $elapsedMs = round((microtime(true) - $start) * 1000, 2);

        // Call again — should be instant (cache hit)
        $start2     = microtime(true);
        $count2     = $service->countItems();
        $elapsedMs2 = round((microtime(true) - $start2) * 1000, 2);

        return Response::json([
            'feature'        => 'AOP #[Cache]',
            'description'    => 'First call runs the COUNT query (cache miss); second call hits the cache.',
            'item_count'     => $count,
            'first_call_ms'  => $elapsedMs,
            'second_call_ms' => $elapsedMs2,
            'same_result'    => $count === $count2,
        ]);
    }

    /**
     * GET /features/events — dispatch a PSR-14 event and show listener output.
     */
    public function eventsAction(FeatureService $service): Response
    {
        $title = 'Event Item ' . date('Y-m-d H:i:s');
        $id    = $service->createItemTransactional($title);

        // The listener already ran during dispatch inside createItemTransactional.
        // To show the event/log, we dispatch a fresh event and capture it.
        $event = new ItemCreated($id, $title);
        $this->context()->events()->dispatch($event);

        return Response::json([
            'feature'      => 'PSR-14 Events',
            'description'  => 'Dispatched ItemCreated; the listener stamped the event with a log entry.',
            'event_class'  => ItemCreated::class,
            'item_id'      => $event->id,
            'item_title'   => $event->title,
            'listener_log' => $event->log(),
        ]);
    }

    /**
     * GET /features/rate-limit — rate limiter demo (5 requests per 60s).
     */
    public function rateLimitAction(): Response
    {
        $ctx     = $this->context();
        $limiter = new RateLimiter($ctx->cache());
        $ip      = $ctx->request()->server('REMOTE_ADDR', '127.0.0.1');

        $allowed = $limiter->limit('demo:' . $ip, 5, 60);
        $hits    = $limiter->hits('demo:' . $ip);

        return Response::json([
            'feature'     => 'RateLimiter',
            'description' => 'Max 5 requests per 60 seconds per IP. After 5, requests are denied.',
            'ip'          => $ip,
            'hits'        => $hits,
            'allowed'     => $allowed,
            'remaining'   => max(0, 5 - $hits),
        ], $allowed ? 200 : 429);
    }

    /**
     * GET /features/security — show CSRF token + password hash demo.
     */
    public function securityAction(): Response
    {
        $ctx    = $this->context();
        $hasher = new Hasher();

        // Demo: hash a sample password and verify it
        $plainPassword = 's3cur3-d3m0-p@ss';
        $hash          = $hasher->make($plainPassword);
        $verifyOk      = $hasher->verify($plainPassword, $hash);
        $verifyWrong   = $hasher->verify('wrong-password', $hash);

        // Generate a CSRF token (if session is available)
        $csrfMiddleware = new CsrfMiddleware();
        $session        = $ctx->session();
        $csrfToken      = null;
        if ($session !== null) {
            $csrfToken = $csrfMiddleware->ensureToken($session);
        }

        return Response::json([
            'feature'        => 'Security (Hasher + CSRF)',
            'description'    => 'Password hashing via PHP password_hash() and CSRF token generation.',
            'hash'           => $hash,
            'verify_correct' => $verifyOk,
            'verify_wrong'   => $verifyWrong,
            'needs_rehash'   => $hasher->needsRehash($hash),
            'csrf_token'     => $csrfToken,
            'csrf_note'      => $csrfToken !== null
                ? 'Submit this token as _csrf_token in a POST to /features/security'
                : 'No session available — SessionMiddleware must run first',
        ]);
    }

    /**
     * POST /features/security — CSRF-protected endpoint.
     *
     * Validates the CSRF token from the POST body or X-CSRF-Token header.
     * Returns 419 if the token is missing or mismatched.
     */
    public function securityPostAction(): Response
    {
        $ctx        = $this->context();
        $middleware = new CsrfMiddleware();

        $called = false;
        $result = $middleware->process($ctx, function () use (&$called) {
            $called = true;
            return null;
        });

        if ($result !== null) {
            // CSRF validation failed — middleware returned a 419 response
            return $result;
        }

        return Response::json([
            'feature'     => 'CSRF Protection',
            'description' => 'POST request passed CSRF token validation.',
            'csrf_valid'  => true,
            'post_data'   => $ctx->request()->post(),
        ]);
    }

    /**
     * GET /features/log — demonstrate #[Log] AOP logging.
     */
    public function logAction(MemoryLogger $logger, FeatureService $service): Response
    {
        $logger->clear();
        $result = $service->logSomething('hello from the #[Log] demo');

        return Response::json([
            'feature'     => 'AOP #[Log]',
            'description' => 'LogInterceptor logs method entry, exit (with duration), and exceptions via PSR-3.',
            'result'      => $result,
            'log_entries' => $logger->entries(),
        ]);
    }

    /**
     * GET /features/retry — demonstrate #[Retry] AOP retry.
     */
    public function retryAction(FeatureService $service): Response
    {
        $result = $service->flakyOperation();

        return Response::json([
            'feature'     => 'AOP #[Retry]',
            'description' => 'RetryInterceptor retries a failing method up to `times` attempts (including the first).',
            'result'      => $result,
        ]);
    }

    /**
     * GET /features/db-events — demonstrate the Db event pipeline.
     */
    public function dbEventsAction(DbEventLog $log, FeatureService $service): Response
    {
        $log->clear();

        // Run a couple of queries + a transaction so the Db events fire.
        // The count deliberately bypasses the #[Cache] demo (countItems()):
        // a cached hit fires no Db events, so this row must use the plain
        // query path.
        $service->createItemTransactional('DbEvent Item ' . date('Y-m-d H:i:s'));
        $service->countItemsQuery();

        return Response::json([
            'feature'     => 'Db Events',
            'description' => 'Database dispatches QueryExecuted, StatementPrepared, TransactionStarted, TransactionCommitted via PSR-14.',
            'events'      => $log->all(),
        ]);
    }

    /**
     * GET /features/validation — demonstrate the Validator.
     *
     * Validates a sample payload (valid and invalid) and shows the
     * validated/coerced data plus any error messages.
     */
    public function validationAction(): Response
    {
        // A valid payload — all rules pass.
        $valid = new Validator([
            'name'  => 'Ada Lovelace',
            'email' => 'ada@example.com',
            'age'   => '36',
            'tags'  => ['math', 'code'],
        ]);
        $valid->field('name')->required()->string()->min(2)->max(100);
        $valid->field('email')->required()->email()->max(255);
        $valid->field('age')->optional()->int()->min(18)->max(120);
        $valid->field('tags')->optional()->list(fn($f) => $f->string()->max(50));

        // An invalid payload — several rules fail.
        $invalid = new Validator([
            'name'  => 'X',
            'email' => 'not-an-email',
            'age'   => '150',
        ]);
        $invalid->field('name')->required()->string()->min(2)->max(100);
        $invalid->field('email')->required()->email()->max(255);
        $invalid->field('age')->optional()->int()->min(18)->max(120);

        return Response::json([
            'feature'       => 'Validation',
            'description'   => 'Validator coerces and validates input; errors are keyed by dot-path field name.',
            'valid_payload' => [
                'passed' => !$valid->fails(),
                'data'   => $valid->validated(),
                'errors' => $valid->errors(),
            ],
            'invalid_payload' => [
                'passed' => !$invalid->fails(),
                'data'   => $invalid->validated(),
                'errors' => $invalid->errors(),
            ],
        ]);
    }

    /**
     * GET /features/config — demonstrate the Config dot-notation service.
     */
    public function configAction(): Response
    {
        $config = $this->context()->config();

        return Response::json([
            'feature'     => 'Config',
            'description' => 'Dot-notation access to a nested configuration array.',
            'app_name'    => $config->get('app.name'),
            'db_dsn'      => $config->get('db.dsn'),
            'missing'     => $config->get('does.not.exist', 'fallback'),
            'has_app'     => $config->has('app'),
            'all'         => $config->all(),
        ]);
    }

    /**
     * GET /features/request-scoped — demonstrate the RequestScoped lifecycle.
     *
     * Increments a request-scoped counter.  In a long-lived worker the
     * counter is reset by clearRequestScope() between requests; here we
     * call it explicitly to show the reset works.
     */
    public function requestScopedAction(RequestCounter $counter): Response
    {
        $before = $counter->count();
        $after  = $counter->increment();

        // Simulate the end of a request: clear request-scoped state.
        $this->context()->clearRequestScope();

        $afterReset = $counter->count();

        return Response::json([
            'feature'           => 'RequestScoped',
            'description'       => 'Services implementing RequestScoped are reset by clearRequestScope() between requests.',
            'count_before'      => $before,
            'count_after'       => $after,
            'count_after_reset' => $afterReset,
        ]);
    }

    /**
     * GET /features/pipeline — demonstrate the direct (explicit) AOP Pipeline.
     *
     * Unlike the transparent #[Advised] proxy, the Pipeline composes
     * interceptors around a plain callable with NO proxy generation.
     * This is the technique Spiral uses — so it's the fair apples-to-apples
     * comparison for the AOP feature.  The same interceptors work in both
     * modes.
     */
    public function pipelineAction(MemoryLogger $logger): Response
    {
        $logger->clear();

        // Direct pipeline: RetryInterceptor + LogInterceptor around a
        // plain callable.  No proxy class is generated.
        $result = $this->context()->pipeline()
            ->through([
                new RetryInterceptor($logger, defaultTimes: 3, defaultBackoff: 0),
                new LogInterceptor($logger),
            ])
            ->call(fn() => 'direct pipeline result');

        return Response::json([
            'feature'     => 'AOP Pipeline (direct)',
            'description' => 'Explicit interceptor pipeline around a plain callable — no proxy generation. The technique Spiral uses.',
            'result'      => $result,
            'log_entries' => $logger->entries(),
        ]);
    }
}