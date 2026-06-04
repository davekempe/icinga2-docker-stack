# Quickstart

## Requirements

- A Debian/Ubuntu host (the launcher auto-installs Docker from `get.docker.com` if missing).
- **root** — the script installs packages and writes to `/etc`. Run with `sudo`.
- Recommended host size:

  | Resource | Floor (works, painful) | Recommended |
  | -------- | ---------------------- | ----------- |
  | RAM | 2 GB **+ swap** | **4 GB** |
  | Swap | — | 2 GB if RAM < 4 GB |
  | CPU | 2 vCPU | 2 vCPU |
  | Free disk | 15 GB | 20 GB |

  The launcher runs a preflight check and warns (or prompts) if you're under spec.
  On a 2 GB box, add swap first:

  ```bash
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ```

## Run it

```bash
git clone https://github.com/davekempe/icinga2-docker-stack.git
cd icinga2-docker-stack
sudo ./start-with-netbox.sh
```

This will: check resources → install Docker if needed → deploy NetBox
(`netbox-docker`) → build & start the Icinga container → seed demo data → print
URLs and credentials.

First boot takes a few minutes (NetBox migrations, then Icinga MySQL schema
import, Director kickstart and basket imports). The launcher waits up to 10
minutes for Icinga to answer.

## Options

```bash
sudo ./start-with-netbox.sh --help
```

| Option | Purpose |
| ------ | ------- |
| `--external-netbox <URL> <TOKEN>` | Use an existing NetBox instead of deploying one. See [NetBox](netbox.md). |
| `--proxy <url>` | Route outbound traffic through an HTTP proxy. See [Proxy](proxy.md). |
| `--skip-checks` | Skip the preflight RAM/CPU/disk check (or set `SKIP_SPEC_CHECK=1`). |
| `-h`, `--help` | Show usage. |

## Endpoints & credentials

Printed at the end of the run (URLs use the detected host IP):

- Icinga Web 2 — `http://<host>:8002/icingaweb2` (`icingaadmin` / `icinga`)
- NetBox — `http://<host>:8001` (`admin` / `admin`)
- Meerkat — `https://<host>:8888` (open the **Demo** dashboard)

Ports are set near the top of `start-with-netbox.sh` (`NETBOX_PORT=8001`,
`ICINGA_PORT=8002`, `MEERKAT_PORT=8888`); change them there if they clash.

## Re-running

The launcher is idempotent: it reuses the cloned `netbox-docker`, skips
redeploying components that are already running, and updates `secrets_sql.env`
in place. Re-run it after a `git pull` to apply changes (the Icinga image is
rebuilt with `--build`).

## Resetting

```bash
./reset.sh          # destroys containers, images, build cache and ./data
```

For a lighter reset (keep NetBox, rebuild Icinga with a clean config volume):

```bash
docker compose down
sudo rm -rf data/
sudo ./start-with-netbox.sh
```

## Troubleshooting

- **Icinga never comes up / times out:** watch the boot with
  `docker compose logs -f icinga2`. First boot is slow on small hosts; ensure
  you have swap or 4 GB RAM.
- **NetBox marked "unhealthy" during startup:** first-boot migrations/reindex can
  exceed the healthcheck window on small hosts. The launcher already extends it
  to 360 s and trims workers; add swap if it still struggles.
- **A setup step fails and the container restarts in a loop:** `run-parts` runs
  `content/opt/setup/*` with `--exit-on-error`, so one failing step aborts the
  whole boot. The logs name the failing script.
- **Mail not sending:** outbound mail is optional and off by default. Set
  `NOTIFICATION_FROM_ADDRESS` and `GMAIL_SMTP_PASSWORD` in `secrets_sql.env`.
