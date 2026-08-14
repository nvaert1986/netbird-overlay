# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit desktop linux-info systemd xdg-utils

MY_PN="${PN%-bin}"
BASE_URI="https://github.com/netbirdio/netbird/releases/download/v${PV}"

DESCRIPTION="WireGuard-based overlay network with SSO/MFA and centralised access control"
HOMEPAGE="https://netbird.io/ https://github.com/netbirdio/netbird"

# Upstream ships the CLI for amd64/arm64, but the Wails 3 desktop UI is built
# for linux/amd64 only (see .goreleaser_ui.yaml) -- there is no arm64 UI asset.
SRC_URI="
	amd64? ( ${BASE_URI}/${MY_PN}_${PV}_linux_amd64.tar.gz -> ${MY_PN}-${PV}-amd64.tar.gz )
	arm64? ( ${BASE_URI}/${MY_PN}_${PV}_linux_arm64.tar.gz -> ${MY_PN}-${PV}-arm64.tar.gz )
	ui? (
		${BASE_URI}/${MY_PN}-ui-linux_${PV}_linux_amd64.tar.gz -> ${MY_PN}-ui-${PV}-amd64.tar.gz
		https://raw.githubusercontent.com/netbirdio/netbird/v${PV}/client/ui/assets/netbird.png
			-> ${MY_PN}-icon-${PV}.png
	)
"

S="${WORKDIR}"

# The repo is BSD-3-Clause except management/, signal/, relay/ and combined/,
# which are AGPL-3. Those are server components and are not shipped here --
# these archives contain only the client and the desktop UI.
LICENSE="BSD"
SLOT="0"
KEYWORDS="-* ~amd64 ~arm64"
IUSE="+ui"
REQUIRED_USE="ui? ( amd64 )"

# Prebuilt upstream binaries: never strip, and there is no test suite to run.
RESTRICT="strip test"

# The netbird CLI is a statically linked CGO_ENABLED=0 Go binary and needs
# nothing at runtime. Every dependency below comes from netbird-ui, taken from
# its direct DT_NEEDED entries rather than the full transitive ldd output.
#
#   libgtk-4.so.1                 -> gui-libs/gtk:4
#   libgio/libgobject/libglib-2.0 -> dev-libs/glib:2
#   libcairo.so.2                 -> x11-libs/cairo
#   libwebkitgtk-6.0.so.4         -> net-libs/webkit-gtk:6
#   libjavascriptcoregtk-6.0.so.1 -> net-libs/webkit-gtk:6
#   libsoup-3.0.so.0              -> net-libs/libsoup:3.0
#   libX11.so.6                   -> x11-libs/libX11
#
# xdg-open is also invoked (via skratchdot/open-golang) to launch a browser
# for interactive SSO login. Only pulled in with USE=ui so that headless
# installs stay lean -- there, register with `netbird up --setup-key <key>`.
RDEPEND="
	ui? (
		dev-libs/glib:2
		gui-libs/gtk:4
		net-libs/libsoup:3.0
		net-libs/webkit-gtk:6
		x11-libs/cairo
		x11-libs/libX11
		x11-misc/xdg-utils
	)
"

# netbird programs nftables through netlink directly (google/nftables), so no
# userspace firewall binary is required. It only shells out to iptables on the
# legacy fallback path; pull in net-firewall/iptables yourself if you need it.

QA_PREBUILT="usr/bin/${MY_PN} usr/bin/${MY_PN}-ui"

CONFIG_CHECK="~TUN"
ERROR_TUN="CONFIG_TUN is required for netbird to create its WireGuard interface."

pkg_setup() {
	linux-info_pkg_setup
}

src_unpack() {
	# Both archives extract flat and both contain LICENSE/README.md, so they
	# would clobber each other in a shared WORKDIR. Unpack them separately.
	local cli_archive
	if use amd64; then
		cli_archive="${MY_PN}-${PV}-amd64.tar.gz"
	else
		cli_archive="${MY_PN}-${PV}-arm64.tar.gz"
	fi

	mkdir -p "${WORKDIR}"/cli || die
	tar -xzf "${DISTDIR}/${cli_archive}" -C "${WORKDIR}"/cli || die

	if use ui; then
		mkdir -p "${WORKDIR}"/ui || die
		tar -xzf "${DISTDIR}/${MY_PN}-ui-${PV}-amd64.tar.gz" -C "${WORKDIR}"/ui || die
		cp "${DISTDIR}/${MY_PN}-icon-${PV}.png" "${WORKDIR}/${MY_PN}.png" || die
	fi
}

src_install() {
	dobin cli/"${MY_PN}"

	if use ui; then
		dobin ui/"${MY_PN}"-ui
		doicon -s 256 "${WORKDIR}/${MY_PN}.png"
		domenu "${FILESDIR}"/netbird-ui.desktop
	fi

	newinitd "${FILESDIR}"/netbird.initd "${MY_PN}"
	newconfd "${FILESDIR}"/netbird.confd "${MY_PN}"
	systemd_dounit "${FILESDIR}"/netbird.service

	# Upstream only writes this drop-in from `netbird service install`, which
	# this package tells users not to run since it ships its own unit. Without
	# it, systemd-networkd strips NetBird's routes and policy rules. Installed
	# under /usr/lib rather than /etc so Portage owns it and cleans it up;
	# networkd reads drop-ins from both, with /etc winning. Inert on systems
	# not running networkd.
	insinto /usr/lib/systemd/networkd.conf.d
	newins "${FILESDIR}"/99-netbird-networkd.conf 99-netbird.conf

	# Tells the upstream `curl ... install.sh --update` path that this install
	# is managed by a package manager, so it refuses to overwrite our files.
	insinto /etc/netbird
	doins "${FILESDIR}"/install.conf

	# Daemon defaults: --config /var/lib/netbird/default.json and
	# --log-file /var/log/netbird/client.log
	keepdir /var/lib/netbird /var/log/netbird
	fperms 0700 /var/lib/netbird

	dodoc cli/README.md
}

pkg_postinst() {
	if use ui; then
		xdg_icon_cache_update
		xdg_desktop_database_update
	fi

	elog "Do NOT run 'netbird service install' -- this package already ships a"
	elog "service file. Enable the daemon with:"
	elog
	elog "  systemctl enable --now netbird        # systemd"
	elog "  rc-update add netbird default         # OpenRC"
	elog
	elog "Then register this peer:"
	elog
	elog "  netbird up"
	elog
	elog "Extra daemon flags go in /etc/conf.d/netbird (OpenRC) or a systemd"
	elog "drop-in via 'systemctl edit netbird'."

	if [[ -f ${EROOT}/etc/systemd/networkd.conf.d/99-netbird.conf ]]; then
		elog
		elog "A copy of 99-netbird.conf left behind by a previous"
		elog "'netbird service install' was found in /etc/systemd/networkd.conf.d/."
		elog "It overrides the one this package ships and is never cleaned up"
		elog "by netbird itself, so you may remove it:"
		elog
		elog "  rm /etc/systemd/networkd.conf.d/99-netbird.conf"
	fi
}

pkg_postrm() {
	if use ui; then
		xdg_icon_cache_update
		xdg_desktop_database_update
	fi
}
