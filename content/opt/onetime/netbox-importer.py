#!/usr/bin/env python3
"""Idempotent NetBox seeder for the Icinga2 POC stack.

Reads a JSON payload describing tags, contacts, custom fields, sites, devices,
VMs, etc. and creates them in NetBox via the REST API. Safe to run repeatedly.

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
# Order in this dict is also the processing order, so referenced objects
# (manufacturers, sites, clusters, ...) are created before the things that
# reference them.
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

# Nested reference fields -> (endpoint, lookup field). When a payload value is a
# {"slug": "..."} / {"name": "..."} dict for one of these fields, it is resolved
# to the integer id NetBox expects on write. ("type" only fires for dict values,
# i.e. a cluster's cluster-type; custom-field "type" is a plain string.)
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
        # v2 tokens carry the `nbt_` prefix and use Bearer auth; v1 use Token.
        scheme = "Bearer" if token.startswith("nbt_") else "Token"
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"{scheme} {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        })

    def _url(self, endpoint, suffix=""):
        return f"{self.base}/{endpoint}/{suffix}"

    def find(self, endpoint, field, value):
        resp = self.session.get(self._url(endpoint), params={field: value})
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
                obj = self.find(ref_endpoint, ref_field, lookup)
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
        existing = self.find(endpoint, field, payload[field])
        body = self.resolve_refs(payload)

        if existing:
            # Only diff plain scalar fields to avoid false positives on nested
            # representations NetBox returns for FK/choice fields.
            changes = {
                k: v for k, v in body.items()
                if isinstance(v, (str, int, float, bool)) and existing.get(k) != v
            }
            if not changes:
                print(f"  = {endpoint}/{name}: up to date")
                return
            resp = self.session.patch(self._url(endpoint, f"{existing['id']}/"), json=changes)
            if resp.ok:
                print(f"  ~ {endpoint}/{name}: updated {list(changes)}")
            else:
                print(f"  ! {endpoint}/{name}: update failed {resp.status_code} {resp.text}")
            return

        missing = [f for f in required if f not in payload]
        if missing:
            print(f"  ! {endpoint}/{name}: missing required fields {missing}; skipping")
            return
        resp = self.session.post(self._url(endpoint), json=body)
        if resp.ok:
            print(f"  + {endpoint}/{name}: created")
        else:
            print(f"  ! {endpoint}/{name}: create failed {resp.status_code} {resp.text}")


def main():
    args = get_arguments()
    with open(args.file, "r") as fh:
        # Substitute ${VAR} references from the environment (gateway, host specs).
        raw = os.path.expandvars(fh.read())
    data = json.loads(raw)

    nb = NetBox(args.url, args.token)

    for key, (endpoint, field, required) in OBJECT_TYPES.items():
        if key not in data:
            continue
        print(f"Processing {key} -> {endpoint}")
        for payload in data[key]:
            nb.create_or_update(endpoint, field, required, payload)


if __name__ == "__main__":
    try:
        main()
    except requests.RequestException as exc:
        print(f"NetBox request failed: {exc}", file=sys.stderr)
        sys.exit(1)
