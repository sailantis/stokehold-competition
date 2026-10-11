<?php
/**
 * Request-context middleware.
 *
 * Simulates the kind of per-request work that real apps do in middleware:
 *   - reads the Accept-Language header and picks a locale
 *   - reads the User-Agent header and detects a platform
 *   - stamps both into the view engine as global variables
 *
 * Modeled after the sailantis-homepage GeoCurrencyMiddleware but without
 * external API calls or session dependency, so it's self-contained and
 * deterministic.
 */

namespace App\Azera\Middleware;

use Azera\AppContext;
use Azera\Core\MiddlewareInterface;
use Azera\Http\Response;

class RequestContextMiddleware implements MiddlewareInterface
{
    private const LOCALES = [
        'en' => 'en_US',
        'de' => 'de_DE',
        'fr' => 'fr_FR',
        'ja' => 'ja_JP',
        'es' => 'es_ES',
    ];

    /** @var int Request counter, used to simulate per-request state */
    private static int $requestCount = 0;

    public function process(AppContext $ctx, callable $next): ?Response
    {
        // 1) Locale: parse Accept-Language header, pick first supported
        $acceptLang = $ctx->request()->header('Accept-Language', 'en');
        $locale     = 'en_US';
        if (is_string($acceptLang) && $acceptLang !== '') {
            foreach (self::LOCALES as $short => $full) {
                if (stripos($acceptLang, $short) !== false) {
                    $locale = $full;
                    break;
                }
            }
        }

        // 2) Platform: detect from User-Agent
        $userAgent = $ctx->request()->userAgent();
        $platform  = 'desktop';
        if (preg_match('/Mobile|Android|iPhone/i', $userAgent)) {
            $platform = 'mobile';
        } elseif (preg_match('/iPad|Tablet/i', $userAgent)) {
            $platform = 'tablet';
        }

        // 3) Increment request counter (simulates per-request tracking)
        self::$requestCount++;

        // 4) Stamp into view vars so templates can use them
        $ctx->view()
            ->setVar('locale', $locale)
            ->setVar('platform', $platform)
            ->setVar('requestCount', self::$requestCount);

        return $next();
    }

    /**
     * Reset the request counter (called on bootstrap for cold mode).
     */
    public static function reset(): void
    {
        self::$requestCount = 0;
    }
}