<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Log;
use OpenTelemetry\API\Globals;

/**
 * Example of manual instrumentation on top of the Laravel
 * auto-instrumentation. Incoming HTTP requests, Eloquent queries and
 * queue jobs are already traced automatically; here we add a custom
 * child span and a business metric.
 */
class OrderController extends Controller
{
    public function store(): JsonResponse
    {
        $tracer = Globals::tracerProvider()->getTracer('laravel-api');
        $meter = Globals::meterProvider()->getMeter('laravel-api');
        $ordersCreated = $meter->createCounter('orders_created_total', null, 'Number of orders created');

        $span = $tracer->spanBuilder('order.process')->startSpan();
        $scope = $span->activate();

        try {
            $amount = round(mt_rand(500, 50000) / 100, 2);
            $span->setAttribute('order.amount', $amount);

            // ... create the order (DB writes are auto-traced) ...

            $ordersCreated->add(1, ['payment.method' => 'card']);
            Log::info('Order created', ['amount' => $amount]);

            return response()->json(['status' => 'created', 'amount' => $amount]);
        } catch (\Throwable $e) {
            $span->recordException($e);
            Log::error('Order failed', ['exception' => $e->getMessage()]);
            throw $e;
        } finally {
            $scope->detach();
            $span->end();
        }
    }
}
