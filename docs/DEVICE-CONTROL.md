# Restricted device control

CoreNest 0.7 adds real LED modes and Docker container start/stop/restart. It does not
provide a shell, container creation/removal, image pulls, volume deletion or access
to container environment variables. No Docker socket is mounted into the API.

The host broker runs through `corenest-control.socket`, checks Unix peer UIDs and a
root-owned allowlist, and accepts fixed JSON operations only. The HTTP API additionally
requires an administrator device binding, an explicit feature flag, a unique
idempotency key and a ten-second cooldown. Every UI mutation is confirmed in native
SwiftUI. An uncertain result is never automatically retried.

## Operator opt-in

Existing installations remain read-only until the owner configures the broker.
Back up `/opt/corenest`, the persistent pairing SQLite database and the API config
before upgrading. Preserve the state volume, token hashes and tunnel configuration.

1. Install the current `backend/*.py` to `/opt/corenest/backend` as root-owned files.
2. Install `deploy/corenest-control.socket` and `.service` into `/etc/systemd/system`.
3. Create a system group `corenest-control`; add the telemetry user to it. The API
   container needs this supplementary GID, **not** the Docker group.
4. Create root-only `/etc/corenest/control.json` with the schema below. Fill in actual
   peer UIDs, LED sysfs names and container names locally. Never commit this file.
   Add a service drop-in with `ReadWritePaths=` for only those LEDs' resolved sysfs
   directories; the broker otherwise keeps kernel tunables read-only.
5. Bind `/run/corenest-control` to the same path in the API container (read-only);
   set `CORENEST_CONTROL_SOCKET=/run/corenest-control/control.sock` there.
6. Enable the desired API flags in `/data/config.json`. The broker and API must both
   agree. Restart the broker and host exporter, then recreate only the CoreNest API
   container. Authorize a selected phone binding as `admin` locally, or create a new
   explicitly approved administrator QR; never auto-promote every viewer.

```json
{
  "apiUID": 10001,
  "allowedUIDs": [10001, 995],
  "serviceControl": true,
  "deviceReboot": false,
  "ledControl": true,
  "dockerControl": true,
  "leds": {"board:blue": {"name": "Blue status", "trigger": "heartbeat"}},
  "containers": ["example-blog-1"]
}
```

UIDs and LED names above are examples, not hardware defaults. Save the actual system
trigger before enabling manual control. Only sysfs LEDs are manageable; a directly
wired power LED cannot be switched off in software. Changes do not cut board power.

The telemetry UID can only request snapshots, even though it shares the socket
group. Only the configured API UID may request a mutation.

The CoreNest API container is always protected. Keep networking, authentication,
remote-access and infrastructure containers outside the allowlist. The Docker
daemon and its socket confer powerful host access; the narrow broker is intentionally
not a general Docker API proxy. See [Docker Engine security](https://docs.docker.com/engine/security/).

`GET /v1/management` returns only LED mode, container ID/name/image/state and local
control availability. It does not return environment variables, labels, mounts,
ports, addresses or logs. Stale/unavailable host telemetry disables actions.
