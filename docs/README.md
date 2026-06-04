# Documentation

A quick proof-of-concept that brings up **Icinga 2** (with IcingaDB, Icinga Director,
the sol1 NetBox module and Meerkat) alongside **NetBox**, wired together so NetBox
is the source of truth for monitored hosts.

> Not for production. Hard-coded demo credentials, single all-in-one container,
> no scaling. It exists to get the whole ecosystem running in minutes.

## Guides

| Guide | What it covers |
| ----- | -------------- |
| [Overview](overview.md) | Architecture, components, versions, data flow, ports & credentials |
| [Quickstart](quickstart.md) | Requirements, running it, options, resetting, troubleshooting |
| [NetBox](netbox.md) | Bundled NetBox, demo data, and using your **own** NetBox |
| [Proxy](proxy.md) | Running behind an outbound HTTP proxy |
| [Meerkat](meerkat.md) | The dashboards, the demo dashboard, and building your own |

## TL;DR

```bash
sudo ./start-with-netbox.sh            # bundled NetBox + Icinga
sudo ./start-with-netbox.sh --help     # all options
```

See [Quickstart](quickstart.md) to go further.
