# NetBox

NetBox is the source of truth for Icinga's host inventory. Icinga Director's
**NetBox import source** (the sol1 `icingaweb2-module-netbox`, v4.6.0.1) pulls
objects from NetBox and a sync rule turns them into Icinga hosts.

## Bundled NetBox (default)

`sudo ./start-with-netbox.sh` deploys NetBox via `netbox-docker` `5.0.1`
(`netboxcommunity/netbox:v4.6-5.0.1`) on port 8001, with `admin` / `admin`.

### API tokens (v2)

NetBox 4.6 uses the new **v2** token model: `Authorization: Bearer nbt_<key>.<secret>`
(legacy v1 `Token` headers are deprecated, removed in 4.7). The bundled NetBox is
seeded with a fixed demo v2 token:

```
nbt_icingademo01.icinganetboxdemotoken1234567890abcdefghi
```

This is minted by `netbox-docker`'s `super_user.py` from `SUPERUSER_API_KEY`
(12 chars) + `SUPERUSER_API_TOKEN` (the secret), set in the generated
`docker-compose.override.yml`.

### Seeded demo data

On first start the bundled NetBox is seeded (from
`content/opt/onetime/netbox-data.json`, via `netbox-importer.py`) so the sync has
something to import. The seeder is idempotent and creates only what's missing:

- **8.8.8.8 / 1.1.1.1** — Google / Cloudflare public DNS (devices)
- **google.com** — resolved by DNS (device)
- **your default gateway** — detected at runtime (device)
- **this host as a VM** — named after the container, with detected vCPU/RAM

Supporting scaffolding is also created: a site, manufacturers, device types,
roles, a cluster type and cluster, plus the custom fields/tags/contacts the
import source expects. Hosts are named by their **reachable address** (the sync
maps `address` from the NetBox object name), so they go green without needing
IPAM data.

## Using your own NetBox

```bash
sudo ./start-with-netbox.sh --external-netbox https://netbox.example.com <API_TOKEN>
```

- `<URL>` — base URL, **no trailing `/api`**.
- `<API_TOKEN>` — a v2 (`nbt_<key>.<secret>`) or legacy v1 token; auto-detected.
  Needs read access across DCIM / virtualization / tenancy / IPAM.

What changes vs. the bundled path:

1. NetBox is **not** deployed (no clone, no compose up, no 8001 port check).
2. `NETBOX_URL` / `NETBOX_APIKEY` are written to `secrets_sql.env` and substituted
   into the Director import-source baskets at startup
   (`baseurl = <URL>/api`, `apitoken = <TOKEN>`).
3. **Demo seeding is disabled** (`SEED_NETBOX_DEMO=false`) — your NetBox is never
   modified.

### ⚠️ Your NetBox must match the import filter

The import source filters on:

```
status=active & cf_icinga_import_source=default
```

So your NetBox needs a **custom field `icinga_import_source`** (a `select` with a
`default` choice) on `dcim.device` and `virtualization.virtualmachine`, and the
devices/VMs you want monitored must be `active` with that field set to `default`.
Without the custom field, the query returns nothing and **zero hosts import** even
though authentication succeeds.

Three ways to satisfy it:

**A. Already using this convention** → nothing to do.

**B. Add the custom field (recommended).** The seeder is a standalone script —
run just the scaffolding (no demo devices) against your NetBox:

```jsonc
// scaffold.json
{
  "extras.custom-field-choice-sets": [
    {"name":"icinga_import_source_choices",
     "extra_choices":[["no_not_monitor","Do not monitor"],["default","Default"]]}
  ],
  "extras.custom-fields": [
    {"name":"icinga_import_source","type":"select","filter_logic":"loose",
     "weight":"100","search_weight":"100",
     "object_types":["dcim.device","virtualization.virtualmachine"],
     "group_name":"Monitoring","choice_set":{"name":"icinga_import_source_choices"}}
  ]
}
```
```bash
pip install requests
python3 content/opt/onetime/netbox-importer.py \
  --url https://netbox.example.com --token <API_TOKEN> --file scaffold.json
```
Then set `icinga_import_source = Default` on the devices/VMs to monitor.

**C. Change the filter.** In Icinga Web → **Director → Import sources →
(NetBox …) → Modify**, edit `filter` to your own convention (e.g. a tag or role),
then re-run import + sync.

## Triggering & verifying the sync

The `director_sync` supervisor runs sync rules automatically on a schedule. To
force it now, in Icinga Web:

1. **Director → Import sources →** run the import.
2. **Director → Sync rules →** trigger the sync.
3. **Director → Deploy.**

Hosts then appear in Icinga Web (and on the Meerkat demo dashboard if they match).

## Switching NetBox later

Re-run with a different `--external-netbox` (or with no flag to go back to the
bundled one). `NETBOX_URL` / `NETBOX_APIKEY` / `SEED_NETBOX_DEMO` are updated in
`secrets_sql.env` in place without touching your other settings.

## Caveat

The "NetBox" host-action link in Icinga Web is built from the bundled-NetBox
assumption (`MY_EXTERNAL_IP:NETBOX_PORT`), so with an external NetBox that
convenience hyperlink may point at the wrong place. The data sync itself uses
`NETBOX_URL` correctly.
