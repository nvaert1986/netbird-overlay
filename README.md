# netbird-overlay

An example Portage overlay packaging the [NetBird](https://netbird.io/) client.

| Package | Source | Installs | Notes |
|---|---|---|---|
| `net-vpn/netbird-bin` | upstream release binaries | `netbird` + `netbird-ui` | UI behind `ui?`, on by default |

Everything is prebuilt from upstream's GitHub release archives. Nothing is
compiled locally, and every distfile fetches from a URL that already exists —
there is no dependency tarball to generate or host.

## Layout

```
netbird-overlay/
├── metadata/layout.conf
├── profiles/{repo_name,categories}
└── net-vpn/netbird-bin/
    ├── netbird-bin-0.77.0.ebuild
    ├── metadata.xml · Manifest
    └── files/
        ├── netbird.service           # systemd unit
        ├── netbird.initd             # OpenRC service
        ├── netbird.confd             # OpenRC options
        ├── netbird-ui.desktop        # desktop entry for the tray UI
        └── install.conf              # blocks upstream's curl|sh self-updater
```

`files/` is the PMS-defined `FILESDIR` — the standard per-package directory for
auxiliary files (init scripts, desktop entries, patches). Around 6700 packages
in `::gentoo` use one.

## Installing the overlay (as root)

Portage runs as `portage:portage`, so the overlay belongs in the standard
root-owned location, `/var/db/repos/netbird-overlay` — not in a home directory.

```bash
cat > /etc/portage/repos.conf/netbird-overlay.conf <<'EOF'
[netbird-overlay]
location = /var/db/repos/netbird-overlay
sync-type = git
sync-uri = https://github.com/nvaert1986/netbird-overlay.git
auto-sync = yes
masters = gentoo
priority = 50
EOF

emaint sync -r netbird-overlay
```

`emerge --sync` then keeps it current alongside `::gentoo`.

## Installing NetBird

```bash
echo 'net-vpn/netbird-bin ~amd64' >> /etc/portage/package.accept_keywords/netbird
emerge -av net-vpn/netbird-bin
```

Upstream's `install.sh` drops **unowned** binaries into `/usr/bin`, which will
collide. Remove them first; `/var/lib/netbird` is preserved, so your peer
registration survives:

```bash
netbird service stop
netbird service uninstall
rm -f /usr/bin/netbird /usr/bin/netbird-ui
```

Then:

```bash
systemctl enable --now netbird     # or: rc-update add netbird default
netbird up
```

Do **not** run `netbird service install` — the unit is shipped by the package.

## USE flags

| Flag | Default | Effect |
|---|---|---|
| `ui` | on | Installs the `netbird-ui` tray app, its icon and desktop entry, and pulls in GTK4 / WebKitGTK 6 |

`REQUIRED_USE="ui? ( amd64 )"` — upstream builds the UI for linux/amd64 only,
and the arm64 UI asset returns 404. The CLI itself is available for both
amd64 and arm64.

## Runtime notes

The daemon runs as **root**. It cannot drop privileges: it needs `CAP_NET_ADMIN`
and `CAP_NET_RAW` for its whole lifetime to manage the WireGuard interface,
routing table, nftables and DNS, and it ships an SSH server that spawns shells
as other users. Upstream's own generated unit does the same.

Be aware that netbird `chmod`s its control socket to `0666`, so **any local
user can control the VPN**. That is upstream behaviour, not something this
package introduces.

With `USE=ui`, `x11-misc/xdg-utils` is pulled in: both binaries shell out to
`xdg-open` (via `skratchdot/open-golang`) to launch a browser for interactive
SSO. Headless installs can skip the UI and register with a setup key instead:

```bash
netbird up --setup-key <key>          # or --setup-key-file <path>
```

## Why there is no source-built package

The desktop UI cannot be built from source at all. `netbird-ui` is a
**Wails 3** application whose release build runs:

```
wails3 generate bindings -clean=true -ts
cd client/ui/frontend && pnpm install --frozen-lockfile && pnpm build
```

That is a Node/pnpm/Vite frontend build requiring network access, which Portage
forbids in `src_compile`. The `.goreleaser_ui_gtk3.yaml` variant runs the same
frontend step, so targeting GTK3 does not avoid it.

The CLI *is* pure Go (`CGO_ENABLED=0`) and could be built with
`go-module.eclass`, but upstream ships no `vendor/` directory, so it would need
a dependency tarball generated and hosted somewhere (the approach
`net-vpn/tailscale` and ~390 other Go packages in `::gentoo` take), or the
deprecated `EGO_SUM` mechanism with 941 individually fetched module distfiles.
Since the UI has to be prebuilt regardless, shipping both binaries prebuilt
keeps the overlay dependency-free.

## Bumping the version

```bash
cd net-vpn/netbird-bin
mv netbird-bin-0.77.0.ebuild netbird-bin-<new>.ebuild
ebuild netbird-bin-<new>.ebuild manifest
```

Check whether upstream has started publishing an arm64 UI archive before
relaxing `REQUIRED_USE`. Upstream also ships
`netbird-ui-linux-gtk3_<ver>_linux_amd64.tar.gz`, a WebKit2GTK-4.1 build for
systems without `webkit-gtk:6`, if a `gtk3` USE flag is ever wanted.
