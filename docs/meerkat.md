# Meerkat

[Meerkat](https://github.com/meerkat-dashboard/meerkat) is a lightweight
dashboard builder for Icinga 2 checks and hosts. It runs inside the Icinga
container and is served at:

```
https://<host>:8888
```

(Self-signed certificate — your browser will warn.)

## Icinga API auth (automatic)

Meerkat reads live state from the Icinga 2 API. The setup step
`content/opt/setup/65-meerkat` configures `/opt/sol1/meerkat/meerkat.toml` at
startup to use the local API:

- `IcingaURL = https://127.0.0.1:5665`
- `IcingaUsername` / `IcingaPassword` = the Icinga Director API user
  (`icinga2-director`, which has `permissions = ["*"]`)
- `IcingaInsecureTLS = true` (self-signed API cert)

No extra Icinga API user is needed, and nothing manual is required.

## The demo dashboard

A sample dashboard ships at `content/opt/sol1/meerkat/dashboards/demo.json` and
appears as **Demo** in the Meerkat UI. It shows a self-contained host,
`meerkat-demo`, and its services.

That host is defined directly in Icinga
(`content/etc/icinga2/conf.d/meerkat-demo.conf`, preserved through the conf.d
archiving in `/opt/run`), so the dashboard has live data **independently of the
NetBox sync**. Its services:

| Service | Check command | Target |
| ------- | ------------- | ------ |
| Ping | `ping4` | 127.0.0.1 |
| Load | `load` | local |
| Processes | `procs` | local |
| HTTP | `http` | the bundled Apache / Icinga Web on 127.0.0.1 |
| DNS | `dns` | resolves `icinga.com` via the container's resolver |
| SMTP | `smtp` | `smtp.gmail.com:587` (STARTTLS) — the mail relay |

> **SMTP note:** the SMTP check needs outbound TCP 587. If your host blocks egress
> on 587 this service will be CRITICAL — that's a genuine "the check found a
> problem" result, not a config error. Point it elsewhere or remove it in
> `meerkat-demo.conf` if you don't want it.

## Building your own dashboard

1. Open `https://<host>:8888` and click **Create New Dashboard**.
2. Add a background image (optional but recommended — a network diagram, rack
   photo, map…).
3. Add **Elements** (check cards, text, SVG, etc.) and drag them over the
   background.
4. For a check element, set:
   - **objectType**: `host` or `service`
   - **objectName**: the Icinga object name — e.g. `meerkat-demo` (host) or
     `meerkat-demo!Ping` (service, `host!service`)
   - **objectAttr**: usually `state`
5. **Save**, then view it from the Meerkat home page.

### Dashboard storage

Dashboards are JSON files in `/opt/sol1/meerkat/dashboards/` inside the container,
one file per dashboard (`<slug>.json`). The element schema is the Go `Dashboard`
struct in the Meerkat source; `demo.json` is a good template to copy. Rect
coordinates (`x`, `y`, `w`, `h`) are **percentages** of the canvas.

> The container's `/opt/sol1/meerkat` is not a persistent volume, so dashboards
> you create live only for the life of the container. To keep one, copy its JSON
> out (e.g. `docker compose cp`), or add it under
> `content/opt/sol1/meerkat/dashboards/` and rebuild the image.
