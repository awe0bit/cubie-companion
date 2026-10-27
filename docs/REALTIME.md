# Foreground telemetry

`GET /v1/events` is an authenticated SSE endpoint using the same native-only
Bearer / optional Access headers as the JSON API. No token is sent in a URL or
across the React Native bridge. Redirects remain disabled.

The host exporter samples CPU, memory, network rates and temperatures every
second. System service / Docker / LED / campus metadata is sampled every five
seconds and hardware inventory every ten seconds, rather than running slow host
commands each second. All frames retain original sample timestamps. A confirmed
LED action readback supersedes an older exported sample.

Each process admits at most two streams, with six HTTP workers total. Leases
expire after twelve seconds, bounding worker occupancy even when a proxy delays
disconnect detection. A third stream gets 503 without blocking the remaining
read/control workers. Frames are capped at 128 KiB and unchanged values produce
comments rather than invented measurements. Credentials/roles are rechecked
each second, so revoked bindings cannot retain a long-lived authorization.

The iOS scene owns one connection, independent of the selected tab. It closes on
backgrounding, replacement or removal of the binding. Failed connections back
off 2 / 4 / 8 / 16 / 30 seconds before refresh/reconnect. Legacy servers fall
back to five-second polling and are not labeled as real-time. Manual gestures
still coalesce with the single snapshot read and do not start another stream.
The streaming, ordinary read and mutation URLSessions are separate.

One-second sampling is not a guarantee of one-second end-to-end latency:
campus network, Cloudflare and iPhone connectivity can add delay. Missing data
is never synthesized. Screenshot/demo launch mode does not access a real board.
