# Overview

## What it is

A single-command proof-of-concept that stands up a complete Icinga 2 monitoring
stack and a NetBox instance, with NetBox driving Icinga's host inventory via the
Icinga Director NetBox import source.

It is intentionally an all-in-one demo: one container runs Icinga and its
dependencies, and NetBox runs as a separate `netbox-docker` project. This is
**not** a production topology.

## Components & versions

| Component | Version / source |
| --------- | ---------------- |
| Base image | `debian:bookworm` (Icinga packages from the official Icinga repo = latest) |
| Icinga 2, IcingaDB, IcingaDB-Web, Icinga Director | latest from packages.icinga.com |
| sol1 NetBox Director module | `v4.6.0.1` (supports NetBox v2 API tokens) |
| Meerkat dashboards | latest GitHub release |
| NetBox | `v4.6` via `netbox-docker` `5.0.1` (`netboxcommunity/netbox:v4.6-5.0.1`) |
| Database / cache | MariaDB (in-container), Postgres 18 + Valkey 9 (NetBox side) |

## Architecture

```
                 ┌─────────────────────────── Icinga all-in-one container ───────────────────────────┐
                 │  Apache + Icinga Web 2  •  Icinga 2 + IcingaDB  •  Icinga Director  •  Meerkat      │
                 │  MariaDB  •  Redis (IcingaDB)  •  supervisord                                       │
                 └───────────────▲───────────────────────────────────────────────────▲────────────────┘
                                 │ Director NetBox import source (REST, token)         │ Icinga API (Meerkat)
                                 │                                                     │
        ┌────────────────────────┴───────────┐                            (Meerkat reads live state
        │  NetBox (netbox-docker)             │                             from the local Icinga API)
        │  netbox + worker • Postgres • Valkey│
        └─────────────────────────────────────┘
```

Two independent Docker Compose projects:

- **`netbox-docker`** (cloned by the launcher) — NetBox, its worker, Postgres, Valkey.
- **this repo's `docker-compose.yml`** — the Icinga all-in-one container.

They are not on a shared Docker network; Icinga reaches NetBox over the host's
IP and published port.

## Data flow

1. The launcher seeds the **bundled** NetBox with demo devices/VMs — some with a
   primary IP, some name-only (see [NetBox](netbox.md)).
2. Icinga Director's **NetBox import source** pulls objects matching
   `status=active & cf_icinga_import_source=default`.
3. A **sync rule** turns them into Icinga `Host` objects (the host `address` comes
   from the NetBox object name, or its primary IP if set).
4. Icinga monitors them; **IcingaDB** stores state; **Icinga Web 2** displays it.
5. **Meerkat** reads live state from the local Icinga API for dashboards.

There is also a self-contained `meerkat-demo` host defined directly in Icinga
(`content/etc/icinga2/conf.d/meerkat-demo.conf`) so the Meerkat demo dashboard
shows live data even before any NetBox sync — see [Meerkat](meerkat.md).

## Default endpoints & credentials

The launcher auto-detects the host's primary IP and prints these at the end.

| Service | URL | Credentials |
| ------- | --- | ----------- |
| Icinga Web 2 | `http://<host>:8002/icingaweb2` | `icingaadmin` / `icinga` |
| NetBox | `http://<host>:8001` | `admin` / `admin` |
| Meerkat | `https://<host>:8888` | — |

Bundled NetBox API token (v2, demo): `nbt_icingademo01.icinganetboxdemotoken1234567890abcdefghi`

> All credentials are fixed demo values. Do not expose this to untrusted networks.

## Where things live

| Path | Purpose |
| ---- | ------- |
| `start-with-netbox.sh` | The launcher (install Docker, deploy, wire up) |
| `Dockerfile` | The Icinga all-in-one image |
| `docker-compose.yml` | The Icinga service |
| `content/opt/setup/*` | Ordered first-boot setup scripts (run via `run-parts`) |
| `content/opt/onetime/*` | Idempotent data import (baskets, NetBox seeder) |
| `content/etc/icinga2/conf.d/meerkat-demo.conf` | Self-contained demo host + services |
| `content/opt/sol1/meerkat/dashboards/demo.json` | Sample Meerkat dashboard |
| `secrets_sql.env` | Generated runtime secrets (gitignored) |
