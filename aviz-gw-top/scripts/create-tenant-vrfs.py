#!/usr/bin/env python3
"""Create named IPv4 VRFs (tenant-a, tenant-b) on the running VPP.

For the frr-vpp-poc gateway on dpdkvm01 (.187). Each VRF gets a loopback
bound into it with an address, so the table shows connected/local routes
in gw-top instead of only the auto-created specials.

Run with sudo (the VPP API socket is root:vpp):

    sudo python3 /home/ilan/work/fable/aviz-gateway/create-tenant-vrfs.py

Idempotent: re-running skips tables that already exist and VRFs that
already contain an interface. Runtime-only: poc-stop/poc-start wipes it.
"""

import sys

from vpp_papi import VPPApiClient

# (table_id, name, loopback address)
VRFS = (
    (100, "tenant-a", "10.10.101.1/24"),
    (200, "tenant-b", "10.10.102.1/24"),
)


def check(reply, what):
    rv = getattr(reply, "retval", 0)
    if rv != 0:
        sys.exit(f"FAILED: {what} (retval {rv})")


def main():
    client = VPPApiClient(server_address="/run/vpp/api.sock")
    client.connect("create-tenant-vrfs")
    api = client.api
    try:
        existing = {
            int(d.table.table_id): str(d.table.name)
            for d in api.ip_table_dump()
            if not d.table.is_ip6
        }
        # Interfaces already bound per v4 table, to make re-runs harmless.
        if_table = {}
        for d in api.sw_interface_dump():
            idx = int(d.sw_if_index)
            t = api.sw_interface_get_table(sw_if_index=idx, is_ipv6=False)
            if_table.setdefault(int(t.vrf_id), []).append(idx)

        for table_id, name, addr in VRFS:
            if table_id in existing:
                print(f"table {table_id} exists ({existing[table_id]}), not recreating")
            else:
                check(
                    api.ip_table_add_del(
                        is_add=True,
                        table={"table_id": table_id, "is_ip6": False, "name": name},
                    ),
                    f"create table {table_id}",
                )
                print(f"created table {table_id} name={name}")
            if if_table.get(table_id):
                print(f"  {name}: already has interface(s), skipping loopback")
                continue
            r = api.create_loopback()
            check(r, f"create loopback for {name}")
            idx = int(r.sw_if_index)
            check(
                api.sw_interface_set_table(
                    sw_if_index=idx, is_ipv6=False, vrf_id=table_id
                ),
                f"bind loopback {idx} to table {table_id}",
            )
            check(
                api.sw_interface_add_del_address(
                    sw_if_index=idx, is_add=True, prefix=addr
                ),
                f"address {addr} on loopback {idx}",
            )
            # IF_STATUS_API_FLAG_ADMIN_UP = 1
            check(
                api.sw_interface_set_flags(sw_if_index=idx, flags=1),
                f"admin-up loopback {idx}",
            )
            print(f"  {name}: loopback sw_if_index {idx} up with {addr}")

        print("\nverification — IPv4 tables and route counts:")
        for d in api.ip_table_dump():
            t = d.table
            if t.is_ip6:
                continue
            n = len(api.ip_route_dump(table={"table_id": t.table_id, "is_ip6": False}))
            print(f"  table {int(t.table_id):4d}  {str(t.name):20s} {n} routes")
    finally:
        client.disconnect()


if __name__ == "__main__":
    main()
