<?php

declare(strict_types=1);

/**
 * The application, shared by all five arms.
 *
 * Every arm must run the *same* application code or the comparison measures
 * nothing: the only differences between the arms are the server, the transport,
 * and whether the framework's bootstrap is paid once (a resident worker) or on
 * every request (a full CGI SAPI reset, as php-fpm does).
 *
 * `bootstrap()` is the expensive part and that is the entire point of the
 * experiment. `azera-competition` measured it at ~0.47 ms per request, against a
 * `GET /` that returns in ~0.255 ms warm — so a cold arm spends most of its time
 * rebuilding the container it is about to throw away.
 */

use App\Azera\Bootstrap;
use Azera\Http\Request;

/**
 * A status and a body, so "no route matched" is reported as a 404 on every arm
 * rather than as a 200 whose body happens to say so.
 */
final class BenchResult
{
    public function __construct(
        public readonly int $status,
        public readonly string $body,
    ) {
    }
}

final class BenchApp
{
    private ?\Azera\AppContext $ctx = null;

    public function __construct(private readonly string $dbPath)
    {
    }

    /**
     * Boot the framework once. Called before the request loop by the worker, and
     * once per request by the front controller.
     */
    public function bootstrap(): void
    {
        $this->ctx = Bootstrap::boot($this->dbPath);
    }

    /**
     * Dispatch one request and return its status and body.
     *
     * The URI is path plus query, exactly as both servers present it, so the
     * router and the paginator see the same input on every arm.
     */
    public function dispatch(string $method, string $uri): BenchResult
    {
        $ctx = $this->ctx ?? throw new RuntimeException('dispatch() before bootstrap()');

        // A synthetic $_SERVER rather than the real one: the arms differ in
        // whether PHP's CGI SAPI populates it, and letting that leak into the
        // application would make the cold arms do more work than the warm ones
        // for reasons that have nothing to do with the server.
        $server = [
            'REQUEST_URI' => $uri,
            'REQUEST_METHOD' => $method,
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'HTTP_HOST' => 'bench.local',
            'SCRIPT_NAME' => '/index.php',
        ];

        $request = new Request($server);
        $ctx->set(Request::class, $request);

        $route = $ctx->router()->match($request->path(), $request->method());
        if ($route === null) {
            return new BenchResult(404, '<h1>404 Not Found</h1>');
        }

        $response = $ctx->dispatcher()->dispatch($route);

        return new BenchResult($response->getStatus(), $response->getBody());
    }

    /**
     * The resident-worker contract: drop this request's state before the next
     * one.
     *
     * Without it the request-scoped heap and the ORM's entity manager keep every
     * request's entities, which shows up as memory and latency that climb across
     * a run. It must be called even where the arm is cold — a `php-cgi` child
     * serves more than one request in a pool, so "cold" means "re-boots the
     * framework", not "one request per process".
     */
    public function cleanup(): void
    {
        $this->ctx?->clearRequestScope();
    }
}
