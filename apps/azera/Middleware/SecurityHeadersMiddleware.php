<?php
/**
 * Security headers middleware.
 *
 * Sets common security response headers that real apps apply on every
 * request.  This adds a realistic per-request overhead (header inspection
 * + modification) that all full-stack frameworks pay in their middleware
 * pipeline.
 */

namespace App\Azera\Middleware;

use Azera\AppContext;
use Azera\Core\MiddlewareInterface;
use Azera\Http\Response;

class SecurityHeadersMiddleware implements MiddlewareInterface
{
    private const HEADERS = [
        'X-Frame-Options'                   => 'SAMEORIGIN',
        'X-Content-Type-Options'            => 'nosniff',
        'X-XSS-Protection'                  => '1; mode=block',
        'Referrer-Policy'                   => 'strict-origin-when-cross-origin',
        'X-Permitted-Cross-Domain-Policies' => 'none',
    ];

    public function process(AppContext $ctx, callable $next): ?Response
    {
        $response = $next();

        if ($response instanceof Response) {
            foreach (self::HEADERS as $name => $value) {
                $response->setHeader($name, $value);
            }
        }

        return $response;
    }
}