#!/usr/bin/env python3
"""Idempotent NetBox seeder for the Icinga2 POC stack.

Reads a JSON payload describing tags, contacts, custom fields, sites, devices,
VMs, interfaces, IPs, etc. and creates them in NetBox via the REST API. Safe to
run repeatedly.

Uses plain `requests` (no pynetbox dependency) so it works regardless of the
distro-packaged pynetbox version. Supports both NetBox token formats:
  * v2 tokens (NetBox 4.5+) look like `nbt_<key>.<secret>` -> Bearer header
  * v1 (legacy) tokens                                     -> Token header

Values like ${DEFAULT_GATEWAY} / ${VM_NAME} in the JSON are substituted from
the environment before parsing, so the demo data can reference the running
host's gateway and specs.
"""
import argparse
import json
import os
import sys

import requests

# JSON top-level key -> (REST endpoint, lookup field, required fields for create).
# Order is the processing order, so referenced objects (manufacturers, sites,
# clusters, ...) are created before the things that reference them. Interfaces,
# IPs and primary-IP assignment are handled separately, after this loop.
OBJECT_TYPES = {
    "extras.tags": ("extras/tags", "name", ["name", "slug", "color"]),
    "extras.custom-field-choice-sets": (
        "extras/custom-field-choice-sets", "name", ["name", "extra_choices"]),
    "extras.custom-fields": ("extras/custom-fields", "name", ["name", "type", "object_types"]),
    "tenancy.contact-groups": ("tenancy/contact-groups", "name", ["name", "slug"]),
    "tenancy.contacts": ("tenancy/contacts", "name", ["name"]),
    "dcim.manufacturers": ("dcim/manufacturers", "slug", ["name", "slug"]),
    "dcim.device-types": ("dcim/device-types", "slug", ["manufacturer", "model", "slug"]),
    "dcim.device-roles": ("dcim/device-roles", "slug", ["name", "slug"]),
    "dcim.sites": ("dcim/sites", "slug", ["name", "slug", "status"]),
    "virtualization.cluster-types": ("virtualization/cluster-types", "slug", ["name", "slug"]),
    "virtualization.clusters": ("virtualization/clusters", "name", ["name", "type"]),
    "dcim.devices": ("dcim/devices", "name", ["name", "device_type", "role", "site", "status"]),
    "virtualization.virtual-machines": (
        "virtualization/virtual-machines", "name", ["name", "cluster", "status"]),
}

# Nested reference fields -> (endpoint, lookup field). A {"slug"/"name": "..."}
# dict for one of these fields is resolved to the integer id NetBox expects.
FIELD_RESOLVERS = {
    "group": ("tenancy/contact-groups", "name"),
    "choice_set": ("extras/custom-field-choice-sets", "name"),
    "manufacturer": ("dcim/manufacturers", "slug"),
    "device_type": ("dcim/device-types", "slug"),
    "role": ("dcim/device-roles", "slug"),
    "site": ("dcim/sites", "slug"),
    "platform": ("dcim/platforms", "slug"),
    "tenant": ("tenancy/tenants", "slug"),
    "cluster": ("virtualization/clusters", "name"),
    "type": ("virtualization/cluster-types", "slug"),
}

# Per-kind endpoints for the device/VM IPAM chain.
KINDS = {
    "device": {
        "parent_endpoint": "dcim/devices",
        "iface_endpoint": "dcim/interfaces",
        "iface_filter": "device_id",
        "iface_parent_field": "device",
        "assigned_object_type": "dcim.interface",
    },
    "vm": {
        "parent_endpoint": "virtualization/virtual-machines",
        "iface_endpoint": "virtualization/interfaces",
        "iface_filter": "virtual_machine_id",
        "iface_parent_field": "virtual_machine",
        "assigned_object_type": "virtualization.vminterface",
    },
}


def get_arguments():
    parser = argparse.ArgumentParser(description="Import data into NetBox (idempotent)")
    parser.add_argument("--url", required=True,
                        help="Base URL of the NetBox instance (no trailing /api)")
    parser.add_argument("--token", required=True, help="NetBox API token (v1 or v2)")
    parser.add_argument("--file", required=True, help="JSON file containing the payload")
    return parser.parse_args()


class NetBox:
    def __init__(self, url, token):
        self.base = url.rstrip("/")
        if not self.base.endswith("/api"):
            self.base += "/api"
        scheme = "Bearer" if token.startswith("nbt_") else "Token"
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"{scheme} {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        })

    def _url(self, endpoint, suffix=""):
        return f"{self.base}/{endpoint}/{suffix}"

    def find(self, endpoint, params):
        resp = self.session.get(self._url(endpoint), params=params)
        resp.raise_for_status()
        results = resp.json().get("results", [])
        return results[0] if results else None

    def resolve_refs(self, payload):
        """Turn {"slug"/"name": "X"} style references into integer ids for write."""
        resolved = {}
        for key, value in payload.items():
            if isinstance(value, dict) and key in FIELD_RESOLVERS:
                ref_endpoint, ref_field = FIELD_RESOLVERS[key]
                lookup = value.get(ref_field) or next(iter(value.values()))
                obj = self.find(ref_endpoint, {ref_field: lookup})
                if obj:
                    resolved[key] = obj["id"]
                else:
                    print(f"  ! could not resolve {key}={value!r}; sending as-is")
                    resolved[key] = value
            else:
                resolved[key] = value
        return resolved

    def create_or_update(self, endpoint, field, required, payload):
        name = payload.get(field, payload.get("name", "<unknown>"))
        existing = self.find(endpoint, {field: payload[field]})
        body = self.resolve_refs(payload)

        if existing:
            changes = {
                k: v for k, v in body.items()
                if isinstance(v, (str, int, float, bool)) and existing.get(k) != v
            }
            if not changes:
                print(f"  = {endpoint}/{name}: up to date")
                return
            resp = self.session.patch(self._url(endpoint, f"{existing['id']}/"), json=changes)
            print(f"  ~ {endpoint}/{name}: updated {list(changes)}" if resp.ok
                  else f"  ! {endpoint}/{name}: update failed {resp.status_code} {resp.text}")
            return

        missing = [f for f in required if f not in payload]
        if missing:
            print(f"  ! {endpoint}/{name}: missing required fields {missing}; skipping")
            return
        resp = self.session.post(self._url(endpoint), json=body)
        print(f"  + {endpoint}/{name}: created" if resp.ok
              else f"  ! {endpoint}/{name}: create failed {resp.status_code} {resp.text}")

    # --- IPAM chain --------------------------------------------------------
    def ensure_interface(self, kind, payload):
        k = KINDS[kind]
        parent_ref = payload.get(k["iface_parent_field"], {})
        parent_name = parent_ref.get("name")
        ifname = payload.get("name")
        parent = self.find(k["parent_endpoint"], {"name": parent_name}) if parent_name else None
        if not parent:
            print(f"  ! interface {parent_name}/{ifname}: parent {kind} not found; skipping")
            return
        existing = self.find(k["iface_endpoint"], {k["iface_filter"]: parent["id"], "name": ifname})
        if existing:
            print(f"  = {k['iface_endpoint']}/{parent_name}/{ifname}: up to date")
            return
        body = {k["iface_parent_field"]: parent["id"], "name": ifname}
        if kind == "device":
            body["type"] = payload.get("type", "virtual")
        resp = self.session.post(self._url(k["iface_endpoint"]), json=body)
        print(f"  + {k['iface_endpoint']}/{parent_name}/{ifname}: created" if resp.ok
              else f"  ! interface {parent_name}/{ifname}: failed {resp.status_code} {resp.text}")

    def find_interface(self, kind, parent_name, ifname):
        k = KINDS[kind]
        parent = self.find(k["parent_endpoint"], {"name": parent_name})
        if not parent:
            return None
        return self.find(k["iface_endpoint"], {k["iface_filter"]: parent["id"], "name": ifname})

    def ensure_ip(self, payload):
        address = payload["address"]
        existing = self.find("ipam/ip-addresses", {"address": address})
        if existing:
            print(f"  = ipam/ip-addresses/{address}: up to date")
            return
        body = {"address": address, "status": payload.get("status", "active")}
        assign = payload.get("assign")
        if assign:
            iface = self.find_interface(assign["kind"], assign["parent"], assign["interface"])
            if iface:
                body["assigned_object_type"] = KINDS[assign["kind"]]["assigned_object_type"]
                body["assigned_object_id"] = iface["id"]
            else:
                print(f"  ! ipam/ip-addresses/{address}: interface "
                      f"{assign['parent']}/{assign['interface']} not found; creating unassigned")
        resp = self.session.post(self._url("ipam/ip-addresses"), json=body)
        print(f"  + ipam/ip-addresses/{address}: created" if resp.ok
              else f"  ! ipam/ip-addresses/{address}: failed {resp.status_code} {resp.text}")

    def set_primary_ip(self, kind, name, address):
        k = KINDS[kind]
        obj = self.find(k["parent_endpoint"], {"name": name})
        ip = self.find("ipam/ip-addresses", {"address": address})
        if not obj or not ip:
            print(f"  ! primary_ip {kind}/{name} -> {address}: object or IP not found; skipping")
            return
        current = (obj.get("primary_ip4") or {}).get("id")
        if current == ip["id"]:
            print(f"  = primary_ip {kind}/{name}: up to date")
            return
        resp = self.session.patch(self._url(k["parent_endpoint"], f"{obj['id']}/"),
                                  json={"primary_ip4": ip["id"]})
        print(f"  ~ primary_ip {kind}/{name} -> {address}: set" if resp.ok
              else f"  ! primary_ip {kind}/{name}: failed {resp.status_code} {resp.text}")


def main():
    args = get_arguments()
    with open(args.file, "r") as fh:
        raw = os.path.expandvars(fh.read())
    data = json.loads(raw)

    nb = NetBox(args.url, args.token)

    # 1. Simple objects (in dependency order).
    for key, (endpoint, field, required) in OBJECT_TYPES.items():
        if key not in data:
            continue
        print(f"Processing {key} -> {endpoint}")
        for payload in data[key]:
            nb.create_or_update(endpoint, field, required, payload)

    # 2. Interfaces (need their parent device/VM to exist first).
    for payload in data.get("dcim.interfaces", []):
        nb.ensure_interface("device", payload)
    for payload in data.get("virtualization.interfaces", []):
        nb.ensure_interface("vm", payload)

    # 3. IP addresses (assigned to the interfaces above).
    for payload in data.get("ipam.ip-addresses", []):
        nb.ensure_ip(payload)

    # 4. Promote IPs to primary so the Director sync uses them as host address.
    for payload in data.get("primary-ips", []):
        nb.set_primary_ip(payload["kind"], payload["name"], payload["address"])


if __name__ == "__main__":
    try:
        main()
    except requests.RequestException as exc:
        print(f"NetBox request failed: {exc}", file=sys.stderr)
        sys.exit(1)
