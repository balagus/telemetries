<?php

/*
 * OTLP log channel for Laravel. Merge this entry into the `channels`
 * array of your config/logging.php, then set LOG_CHANNEL=otel or add
 * 'otel' to your stack channel. Log records are exported with the
 * active trace/span IDs so Grafana can jump from logs to traces.
 */

use Monolog\Level;

return [
    'otel' => [
        'driver' => 'monolog',
        'handler' => \OpenTelemetry\Contrib\Logs\Monolog\Handler::class,
        'with' => [
            'level' => Level::Info,
            'bubble' => true,
        ],
    ],
];
