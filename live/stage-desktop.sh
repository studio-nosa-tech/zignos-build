#!/bin/sh
# Stage a sanitized copy of the running ZIGNOS desktop for the Live ISO.
# Run as root. The result is /var/tmp/desktop-live/root.
set -e

ROOT=/var/tmp/desktop-live/root
# Host account to strip from the image (set SOURCE_USER for your build host).
SOURCE_USER=${SOURCE_USER:-zignos}
# Extra strings to scan for (username, hostname, IP prefix, secrets).
# Set this in the environment; do not commit local values.
LIVE_SANITIZE_PATTERNS=${LIVE_SANITIZE_PATTERNS:-}
log() { printf '\n== %s\n' "$*"; }
die() { echo "stage-desktop: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d /var/lib/zpkg ] || die "not a ZIGNOS system"
[ -x /usr/bin/kwin_wayland ] || die "KDE Plasma is not installed"

log "cloning the running system into $ROOT"
rm -rf "$ROOT"
mkdir -p "$ROOT"
tar -C / \
	--exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
	--exclude='./run/*' --exclude='./tmp/*' --exclude='./var/tmp/*' \
	--exclude='./home/*' --exclude='./root/*' \
	--exclude='./opt/discord/*' \
	--exclude='./mnt/*' --exclude='./media/*' --exclude='./srv/*' \
	--exclude='./lost+found' --exclude='./m46img' \
	--exclude='./var/cache/*' --exclude='./var/log/*' \
	--exclude='./var/lib/flatpak/*' \
	--exclude='./var/lib/NetworkManager/*' \
	--exclude='./var/lib/bluetooth/*' \
	--exclude='./var/lib/sddm/*' \
	--exclude='./var/lib/plasmalogin/*' \
	--exclude='./var/lib/AccountsService/*' \
	--exclude='./var/lib/upower/*' \
	--exclude='./var/lib/alsa/*' \
	--exclude='./var/lib/chrony/*' \
	--exclude='./var/lib/colord/*' \
	--exclude='./var/lib/dhcpcd/*' \
	--exclude='./var/lib/seedrng/*' \
	--exclude='./var/lib/polkit-1/*' \
	--exclude='./var/lib/systemd/*' \
	--exclude='./var/lib/elogind/*' \
	--exclude='./var/spool/*' --exclude='./var/mail/*' \
	--exclude='./var/backups/*' \
	--exclude='./var/lib/dbus/machine-id' \
	--exclude='./usr/lib/llvm-23/*' \
	--exclude='./usr/lib/rustlib/*' \
	--exclude='./usr/lib/librustc_driver*' \
	--exclude='./usr/lib/libLLVM.so.23.1-rust*' \
	--exclude='./usr/local/*' \
	--exclude='./usr/bin/rustc' --exclude='./usr/bin/cargo' \
	--exclude='./usr/bin/rust-*' \
	--exclude='./usr/share/doc/*' --exclude='./usr/share/man/*' \
	--exclude='./usr/share/info/*' \
	--exclude='./etc/ssh/ssh_host_*' \
	--exclude='./etc/NetworkManager/system-connections/*' \
	--exclude='./etc/shadow-' --exclude='./etc/passwd-' \
	--exclude='./etc/group-' --exclude='./etc/gshadow-' \
	--exclude='./etc/sudoers.d/*' --exclude='./etc/crypttab' \
	-cf - . | tar -C "$ROOT" -xf -

log "sanitizing the live root"
mkdir -p "$ROOT"/{proc,sys,dev,run,tmp,var/tmp,var/log,var/spool/cron,var/mail,var/backups,root,home/live,mnt,media,srv}
chmod 1777 "$ROOT/tmp" "$ROOT/var/tmp"
chmod 700 "$ROOT/root"
rm -rf "$ROOT/usr/lib/llvm-23" "$ROOT/usr/lib/rustlib" \
	"$ROOT/usr/local" "$ROOT/usr/share/doc" "$ROOT/usr/share/man" \
	"$ROOT/usr/share/info"

echo zignos-live > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<'EOF'
127.0.0.1       localhost
::1             localhost
127.0.1.1       zignos-live
EOF
MID=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
echo "$MID" > "$ROOT/etc/machine-id"
mkdir -p "$ROOT/var/lib/dbus"
echo "$MID" > "$ROOT/var/lib/dbus/machine-id"

cat > "$ROOT/etc/os-release" <<'EOF'
NAME="ZIGNOS"
PRETTY_NAME="ZIGNOS 2026.11.24 Live"
ID=zignos
VERSION_ID="2026.11.24"
VERSION="2026.11.24 (live)"
VERSION_CODENAME=stable
ANSI_COLOR="38;2;124;92;255"
HOME_URL="https://studio-nosa-tech.github.io/"
BUG_REPORT_URL="https://github.com/studio-nosa-tech/zignos/issues"
LOGO=zignos
VARIANT_ID=live
EOF
cat > "$ROOT/etc/zignos-release" <<'EOF'
NAME="ZIGNOS"
PRETTY_NAME="ZIGNOS 2026.11.24 Live"
ID=zignos
VARIANT_ID=live
EOF
cat > "$ROOT/etc/motd" <<'EOF'
Welcome to ZIGNOS Live (2026.11.24)

This is a live desktop environment. The system runs from a read-only
squashfs image with a writable tmpfs overlay; changes are lost on reboot.

  NetworkManager   network configuration (plasma-nm applet)
  doas             root commands without a password (wheel)
  zpkg             package manager

Documentation: https://studio-nosa-tech.github.io/docs/
EOF
cat > "$ROOT/etc/conf.d/hostname" <<'EOF'
hostname="zignos-live"
EOF
rm -f "$ROOT/etc/conf.d/staticroute" "$ROOT/etc/resolv.conf"
cat > "$ROOT/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
cat > "$ROOT/etc/fstab" <<'EOF'
proc  /proc proc  defaults        0 0
sysfs /sys  sysfs defaults        0 0
tmpfs /tmp  tmpfs mode=1777       0 0
EOF
rm -f "$ROOT/etc/crypttab" "$ROOT/etc/adjtime" "$ROOT/etc/mtab"

# Remove the host's user accounts and add the live account.
for f in passwd shadow group gshadow subuid subgid; do
	[ -f "$ROOT/etc/$f" ] && sed -i "/^\($SOURCE_USER\|zignos\):/d" "$ROOT/etc/$f"
done
awk -F: -v src="$SOURCE_USER" 'BEGIN{OFS=":"} { if (NF>=4) { n=split($4,a,","); out=""; for(i=1;i<=n;i++) if(a[i]!=src && a[i]!="zignos" && a[i]!="") out=out (out?",""") a[i]; $4=out } print }' \
	"$ROOT/etc/group" > "$ROOT/etc/group.new"
mv "$ROOT/etc/group.new" "$ROOT/etc/group"
awk -F: -v src="$SOURCE_USER" 'BEGIN{OFS=":"} { if (NF>=4) { n=split($3,a,","); out=""; for(i=1;i<=n;i++) if(a[i]!=src && a[i]!="zignos" && a[i]!="") out=out (out?",""") a[i]; $3=out; n=split($4,b,","); out=""; for(i=1;i<=n;i++) if(b[i]!=src && b[i]!="zignos" && b[i]!="") out=out (out?",""") b[i]; $4=out } print }' \
	"$ROOT/etc/gshadow" > "$ROOT/etc/gshadow.new"
mv "$ROOT/etc/gshadow.new" "$ROOT/etc/gshadow"
grep -q '^live:' "$ROOT/etc/passwd" ||
	echo 'live:x:1000:1000:ZIGNOS Live:/home/live:/bin/bash' >> "$ROOT/etc/passwd"
grep -q '^live:' "$ROOT/etc/group" || echo 'live:x:1000:' >> "$ROOT/etc/group"
grep -q '^live:' "$ROOT/etc/shadow" || echo 'live::20777:0:99999:7:::' >> "$ROOT/etc/shadow"
grep -q '^live:' "$ROOT/etc/gshadow" || echo 'live:!::' >> "$ROOT/etc/gshadow"
for g in wheel audio video render input; do
	awk -F: -v g="$g" 'BEGIN{OFS=":"} $1==g { if ($4=="") $4="live"; else if ($4 !~ /(^|,)live(,|$)/) $4=$4",live" } {print}' \
		"$ROOT/etc/group" > "$ROOT/etc/group.new"
	mv "$ROOT/etc/group.new" "$ROOT/etc/group"
done
sed -i 's/^root:[^:]*:/root::/' "$ROOT/etc/shadow"
cat > "$ROOT/etc/doas.conf" <<'EOF'
permit nopass :wheel
EOF

mkdir -p "$ROOT/home/live"
cat > "$ROOT/home/live/.bashrc" <<'EOF'
PS1='\[\e[1;35m\]live@zignos\[\e[0m\]:\w\$ '
export EDITOR=vi
EOF
chown -R 1000:1000 "$ROOT/home/live"

# SDDM autologin to the Plasma Wayland session.
mkdir -p "$ROOT/etc/sddm.conf.d"
cat > "$ROOT/etc/sddm.conf.d/20-live-autologin.conf" <<'EOF'
[Autologin]
User=live
Session=plasma
Relogin=false
EOF

# Live runlevels: NetworkManager + SDDM; no host-only services.
rm -f "$ROOT"/etc/runlevels/default/{plasmalogin,sshd,chronyd,console-vga,netmount}
rm -f "$ROOT"/etc/runlevels/boot/{fsck,root,root-rw,staticroute}
ln -sf /etc/init.d/sddm "$ROOT/etc/runlevels/default/sddm"
for s in dbus elogind polkit networkmanager upower local console; do
	[ -x "$ROOT/etc/init.d/$s" ] &&
		ln -sf "/etc/init.d/$s" "$ROOT/etc/runlevels/default/$s"
done
sed -i 's/command_args_foreground="ttyS0 115200 vt100"/command_args_foreground="--autologin root ttyS0 115200 vt100"/' \
	"$ROOT/etc/init.d/console"

# Runtime directories owned by their services.
mkdir -p "$ROOT/var/lib/flatpak" "$ROOT/var/cache/flatpak" \
	"$ROOT/var/lib/NetworkManager" "$ROOT/var/lib/sddm"
chmod 755 "$ROOT/var/lib/flatpak" "$ROOT/var/cache/flatpak" "$ROOT/var/lib/NetworkManager"
chown sddm:sddm "$ROOT/var/lib/sddm" 2>/dev/null || true
chmod 700 "$ROOT/var/lib/sddm"

# The host builds Mesa for its own GPU; keep the built driver set, but do
# not carry a build-time typo or the host-only LLVM path.
sed -i 's/^CFLAGS=.*/CFLAGS="-O2 -pipe"/' "$ROOT/etc/zpkg/make.conf"
rm -f "$ROOT/etc/ld.so.conf.d/llvm-23.conf"
ldconfig -r "$ROOT" 2>/dev/null || true

# Remove launchers for packages that are not included.
rm -f "$ROOT/usr/bin/discord" "$ROOT/usr/share/applications/discord.desktop"
rm -f "$ROOT/usr/bin/go"

# Drop any host-specific files that the package list does not own.
rm -rf "$ROOT"/etc/NetworkManager/system-connections
mkdir -p "$ROOT/etc/NetworkManager/system-connections"
chmod 700 "$ROOT/etc/NetworkManager/system-connections"

log "checking for personal data"
for pat in ${LIVE_SANITIZE_PATTERNS:-}; do
	if grep -RIl "$pat" "$ROOT/etc" "$ROOT/var/lib/zpkg" \
		"$ROOT/usr/share/zignos" 2>/dev/null | head -5 | grep -q .; then
		echo "stage-desktop: found '$pat' in:" >&2
		grep -RIl "$pat" "$ROOT/etc" "$ROOT/var/lib/zpkg" \
			"$ROOT/usr/share/zignos" 2>/dev/null | head -5 >&2
		die "personal data remains"
	fi
done
echo "stage-desktop: no personal data found in /etc, /var/lib/zpkg, /usr/share/zignos"
du -sh "$ROOT"
