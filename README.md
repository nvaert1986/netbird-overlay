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
    ├── netbird-bin-0.82.0.ebuild      # kept as a fallback, see Upgrading
    ├── netbird-bin-0.83.0.ebuild
    ├── metadata.xml · Manifest
    └── files/
        ├── netbird.service            # systemd unit
        ├── netbird.initd              # OpenRC service
        ├── netbird.confd              # OpenRC options
        ├── org.wails.netbird.desktop  # desktop entry for the tray UI
        ├── io.netbird.settings.policy # polkit action for the UI's pkexec prompt
        ├── 99-netbird-networkd.conf   # stops networkd stripping NetBird's routes
        └── install.conf               # blocks upstream's curl|sh self-updater
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

## Upgrading

Portage does not restart the daemon, so do it yourself after the merge. Every
merge rewrites `netbird.service`, so `pkg_postinst` runs `systemctl
daemon-reload` for you when merging into the live system. It skips that
when merging with `ROOT` set or into a chroot without a running systemd, so
the systemd line below still reloads; a second reload is harmless.

```bash
emaint sync -r netbird-overlay
emerge -av net-vpn/netbird-bin

systemctl daemon-reload && systemctl restart netbird    # systemd
rc-service netbird restart                              # OpenRC
```

The restart is left to you on purpose: if you are connected over the NetBird
mesh, it drops that session.

0.82.0 stays in the overlay as a fallback for 0.83.0, which changes how
profiles are stored (see Runtime notes). The first 0.83.0 start migrates
`/var/lib/netbird` in place, so back it up before upgrading if you may want
to go back:

```bash
systemctl stop netbird
cp -a /var/lib/netbird /var/lib/netbird.pre-0.83
emerge -av =net-vpn/netbird-bin-0.83.0
systemctl start netbird

# To revert:
systemctl stop netbird
emerge -av1 =net-vpn/netbird-bin-0.82.0
rm -rf /var/lib/netbird && mv /var/lib/netbird.pre-0.83 /var/lib/netbird
systemctl start netbird
```

With both versions in the overlay, `emerge -u` picks 0.83.0. To stay on 0.82.0,
mask the newer one: `echo '>=net-vpn/netbird-bin-0.83.0' >>
/etc/portage/package.mask/netbird`.

## USE flags

| Flag | Default | Effect |
|---|---|---|
| `ui` | on | Installs the `netbird-ui` tray app, its icon and desktop entry, and pulls in GTK4 / WebKitGTK 6 |

`REQUIRED_USE="ui? ( amd64 )"` — upstream builds the UI for linux/amd64 only,
and the arm64 UI asset returns 404. The CLI itself is available for both
amd64 and arm64.

## Runtime notes

`app-misc/ca-certificates` is required regardless of USE: the CLI verifies TLS
to the management and signal servers against the system trust store and embeds
no fallback root bundle. Upstream's rpm declares the same dependency.

The daemon runs as **root**. It cannot drop privileges: it needs `CAP_NET_ADMIN`
and `CAP_NET_RAW` for its whole lifetime to manage the WireGuard interface,
routing table, nftables and DNS, and it ships an SSH server that spawns shells
as other users. Upstream's own generated unit does the same.

The control socket is `0666`, so any local user can connect to it. Since
0.83.0 the daemon decides what each caller may do from its kernel-attested
uid: every profile has an owner, and users can only see and control their
own. Existing profiles are handed to the account that last used them on the
first start. An unowned `default` profile goes to the first non-root user
holding the active local session, which is read from logind (systemd or
elogind). Without logind, or on a headless machine, root claims it:

```bash
netbird profile list --show-owner
netbird profile claim default --owner <user>
```

Upstream configures the rest through `netbird service install`, which this
package does not use. Set the same options on the packaged service instead:

| Option | Effect |
|---|---|
| `--allow-group <group>` | Socket becomes `0660` for that group; other accounts cannot connect. Prefer `gid:<n>`, which needs no group lookup at boot |
| `NB_DISABLE_PROFILE_OWNERSHIP=true` | All local users share all profiles; pair it with `--allow-group` |
| `NB_DISABLE_DEFAULT_PROFILE_CLAIM=true` | The `default` profile stays unowned until root claims it, recommended on servers |

On OpenRC, `/etc/conf.d/netbird` carries commented examples. On systemd, run
`systemctl edit netbird` and add, for example:

```ini
[Service]
Environment=NB_DISABLE_DEFAULT_PROFILE_CLAIM=true
ExecStart=
ExecStart=/usr/bin/netbird service run --allow-group gid:1001
```

`--daemon-addr tcp://…` stops working in 0.83.0, because a TCP connection
carries no caller identity. The packaged units use the default Unix socket.

The systemd unit orders after `network.target`, not `network-online.target`,
the same as upstream's own unit. The daemon retries its management connection
by itself. Waiting for "online" only delays the control socket, by up to two
minutes when `systemd-networkd-wait-online` is enabled but networkd manages
no links (the usual case when NetworkManager handles WiFi).

With `USE=ui`, `x11-misc/xdg-utils` is pulled in: both binaries shell out to
`xdg-open` (via `skratchdot/open-golang`) to launch a browser for interactive
SSO. Headless installs can skip the UI and register with a setup key instead:

```bash
netbird up --setup-key <key>          # or --setup-key-file <path>
```

The certificate posture check (new in 0.81.0) reads its machine store from the
daemon's environment. This package uses upstream's tarball, whose CLI is built
without the `pkcs11` tag (upstream only adds it to the deb/rpm build), so
`NB_CERT_PKCS11_URI` has no effect here. `NB_CERT_STORE_DIR`, a directory of
PEM and TSS2 key files, does work. Set it with `systemctl edit netbird`
(`Environment=`), or with an `export` line in `/etc/conf.d/netbird` on OpenRC.

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
git mv netbird-bin-<old>.ebuild netbird-bin-<new>.ebuild
ebuild netbird-bin-<new>.ebuild manifest
```

Check whether upstream has started publishing an arm64 UI archive before
relaxing `REQUIRED_USE`. Diff `.goreleaser_ui.yaml` and
`client/ui/build/linux/` against the previous tag too — that is where the
vendored desktop entry and polkit action come from, and both have changed
under a version bump before. Upstream also ships
`netbird-ui-linux-gtk3_<ver>_linux_amd64.tar.gz`, a WebKit2GTK-4.1 build for
systems without `webkit-gtk:6`, if a `gtk3` USE flag is ever wanted.

Re-check the runtime dependencies as well: compare `readelf -d netbird-ui`
`NEEDED` entries against the previous release, and look at the `dependencies:`
lists in `.goreleaser.yaml`'s nfpms section, which is how the `ca-certificates`
dependency surfaced. The rpm entries there also list `contents:` such as
`/etc/sysconfig/netbird`; those are RPM conventions that nothing in this
package's units reads, so they need no counterpart here. Verify the
downloaded archives against upstream's `netbird_<ver>_checksums.txt` and
`netbird-ui_<ver>_checksums.txt` before committing the Manifest.

Since 0.81.0 the deb/rpm CLI is a different build (`netbird-pkcs11`) from
the tarball one this package uses. Check that the `archives:` section of
`.goreleaser.yaml` still packs the `netbird`/`netbird-static` builds, and that
`go version -m netbird` still shows `CGO_ENABLED=0`. If the tarball ever picks
up the `pkcs11` tag, the CLI links libc and the Runtime notes above change.

Upstream adds daemon options to `netbird service install`, which this package
replaces with its own unit and init script. Diff `client/cmd/service*.go`
between the tags. A new flag or variable the installer passes to `service run`
needs a counterpart in `files/netbird.confd` and the Runtime notes, as
`--allow-group` did in 0.83.0.

To keep the old version as a fallback, `cp` the ebuild instead of `git mv`.
Both versions then install the same `files/`, so keep changes there valid for
the older one as well.
