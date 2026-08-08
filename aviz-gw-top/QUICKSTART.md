# aviz-gw-top — Quickstart

Copy-paste, from a checkout of this directory. Python 3.11+ and
[uv](https://docs.astral.sh/uv/) assumed (plain `python -m venv` + `pip`
works the same).

```sh
cd aviz-gw-top

# 1. venv + install (the [vpp] extra pulls vpp_papi from PyPI)
uv venv --python 3.12
VIRTUAL_ENV=$PWD/.venv uv pip install -e ".[vpp]"

# 2. try it with zero infrastructure — full animated demo:
.venv/bin/aviz-gw-top --mock

# 3. on a gateway host you need write access to VPP's sockets (root:vpp):
sudo usermod -aG vpp $USER        # then log out/in for the group to apply
vppctl show version               # works without sudo? you're ready

# 4. run against the live gateway:
.venv/bin/aviz-gw-top                  # read-only — the everyday default
.venv/bin/aviz-gw-top --allow-inject   # only when you intend to Send test traffic
```

Call the binary by its full `.venv/bin/…` path as above (always works), or
make the short form work once:

```sh
ln -s "$PWD/.venv/bin/aviz-gw-top" ~/.local/bin/gwtop   # then: gwtop --mock
# or per shell session: source .venv/bin/activate
```

## Keys

| Key | Action |
|-----|--------|
| `1`–`6` | switch screens (Status, Routing, Firewall, NAT, Validation, Cores) |
| `Tab` / `Shift-Tab` | next / previous screen |
| `v` | cycle the VRF view: all → default → each VRF (follows you across screens) |
| `w` | expand per-worker splits (Status top-nodes, Validation node counters) |
| `/` | filter the current screen's tables (`Esc` clears) |
| `←`/`→` or `[`/`]` | switch packets on the Validation screen |
| `Enter` | on a Status node row: per-worker split for that node |
| `p` | pause refresh |
| `q` | quit |

Start on `--mock` and press through the screens — every feature is
demoable there, including a deliberately unresolved route, a dead ACL
rule, a tenant VRF, a DNAT mapping and canned packet traces.

## First-run troubleshooting

* **DISCONNECTED with a socket error** — permissions (step 3 above) or
  non-default socket paths: pass `--stats-socket` / `--api-socket`.
* **Connected but TOP NODES is empty** — the gateway's VPP lacks
  `statseg { per-node-counters on }` in `/etc/vpp/startup.conf` (startup
  option, no runtime toggle). Everything else keeps working; the panel
  title states exactly this.
* **Screens 3/4 empty on a routing-only gateway** — the ACL/NAT plugins
  aren't loaded there; that's expected, not a fault.

For everything else — architecture, per-screen details, VPP version pin,
upgrade checklist — see [README.md](README.md).
