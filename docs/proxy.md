# Running behind a proxy

If the host reaches the internet through an HTTP proxy, pass `--proxy`:

```bash
sudo ./start-with-netbox.sh --proxy http://proxy.example.com:3128
```

The scheme is optional (defaults to `http://`). A proxy is also picked up
automatically from `HTTP_PROXY` / `HTTPS_PROXY` in the environment.

## What it configures

The launcher applies the proxy before anything reaches the internet, across all
outbound paths:

| Flow | How it's proxied |
| ---- | ---------------- |
| Host `apt`, the `get.docker.com` installer, `git clone` | exported `http_proxy`/`https_proxy`/`no_proxy` + `/etc/apt/apt.conf.d/95proxy` |
| Docker daemon **image pulls** (NetBox, Postgres, Valkey, Debian base) | `/etc/systemd/system/docker.service.d/http-proxy.conf` drop-in + `daemon-reload` & restart |
| Icinga image **build** (`apt`/`curl`/`wget` in the Dockerfile) | proxy build args in `docker-compose.yml` (Docker's predefined proxy args), inherited from the env |

## NO_PROXY

`NO_PROXY` is computed so local and container traffic bypasses the proxy:

```
localhost, 127.0.0.1, ::1, <host LAN IP>, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, .local, .internal, .svc
```

The host's detected IP is included explicitly (on some cloud hosts that IP is a
**public** address that wouldn't otherwise be covered by the private ranges).
This keeps the Icinga healthcheck, the importer→NetBox call, container-to-container
traffic and ICMP checks off the proxy.

## Requirements & caveats

- **root + systemd** are required for the Docker daemon drop-in. Without root,
  that step is skipped (with a message); the env / apt / build-arg paths still
  apply.
- Configuring the daemon **restarts Docker**, which bounces any running
  containers (fine on a fresh run; idempotent on re-runs — the launcher waits for
  the daemon to come back).
- An external NetBox on a private address is reached **directly** (it's in
  `NO_PROXY`), not via the proxy — see [NetBox](netbox.md).
