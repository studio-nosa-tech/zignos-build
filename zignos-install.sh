#!/bin/bash
# ZIGNOS installer — copy the RUNNING system onto a target disk and make
# it bootable (UEFI + GPT, or BIOS + MBR, via GRUB). Run INSIDE the running
# ZIGNOS as root.
#
# Usage:
#   zignos-install [--yes] /dev/sdX
#
# The target disk is partitioned and every byte on it is destroyed. When
# run from the desktop Live ISO the live-only bits (the "live" user, the
# SDDM autologin, nopass doas, the serial root autologin and the Live
# identity files) are removed from the target; a regular installed system
# is produced.
#
# A non-root user is created so the system can be used without logging in
# as root. In interactive mode the username/password are asked for; with
# --yes they come from ZIGNOS_USER / ZIGNOS_PASSWORD (defaults: zignos /
# zignos). An SSH public key for that user is taken from the running
# root's /root/.ssh/authorized_keys when present (interactive mode also
# accepts a key pasted at the prompt).
#
# Environment overrides (used by the whiptail front-end):
#   ZIGNOS_FIRMWARE=auto|uefi|bios   target firmware (default: detect)
#   ZIGNOS_HOSTNAME                  hostname (default: zignos)
#   ZIGNOS_LOCALE                    LANG (default: en_US.UTF-8)
#   ZIGNOS_KEYMAP                    console keymap (default: us)
#   ZIGNOS_TIMEZONE                  zoneinfo name (default: UTC)

set -euo pipefail

YES=0
if [ "${1:-}" = "--yes" ]; then
	YES=1
	shift
fi
DISK="${1:-}"

log() { printf '\n== %s\n' "$*"; }
die() { echo "zignos-install: $*" >&2; exit 1; }

# merge_dir <src> <dst>: copy entries that are missing from dst (usr
# wins on duplicates; this also avoids cp's "same file" error on identical
# symlinks).
merge_dir() {
	local f base
	for f in "$1"/*; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		base=${f##*/}
		if [ -e "$2/$base" ] || [ -L "$2/$base" ]; then
			continue
		fi
		cp -a "$f" "$2/"
	done
}

main() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -n "$DISK" ] || { echo "usage: zignos-install [--yes] /dev/sdX" >&2; exit 1; }
	[ -b "$DISK" ] || die "$DISK is not a block device"
	case "$(findmnt -n -o SOURCE /)" in
		"$DISK"|"$DISK"[0-9]*) die "refusing: $DISK is the running root disk" ;;
	esac
	# On a Live ISO the running root is an overlay, so the check above does
	# not see the boot medium. Refuse to install over the ISO/USB we booted.
	local LIVE=0
	grep -q '^VARIANT_ID=live' /etc/os-release 2>/dev/null && LIVE=1
	if [ "$LIVE" = 1 ]; then
		local livesrc liveparent
		livesrc=$(findmnt -n -o SOURCE /run/iso 2>/dev/null | head -n1) || true
		if [ -n "$livesrc" ]; then
			liveparent=$(lsblk -no PKNAME "$livesrc" 2>/dev/null | head -n1) || true
			[ -n "$liveparent" ] && livesrc="/dev/$liveparent"
			[ "$DISK" = "$livesrc" ] && die "refusing: $DISK is the live medium"
		fi
	fi
	# Firmware mode decides the disk layout: UEFI -> GPT + ESP,
	# BIOS -> MBR + one partition. Default to the firmware we booted on;
	# the TUI can override it (the tools for the other mode must be
	# installed either way).
	local UEFI=0
	[ -d /sys/firmware/efi ] && UEFI=1
	case "${ZIGNOS_FIRMWARE:-auto}" in
		uefi) UEFI=1 ;;
		bios) UEFI=0 ;;
		auto|"") ;;
		*) die "ZIGNOS_FIRMWARE must be auto, uefi or bios" ;;
	esac
	# Live ISO installs must strip the live-only configuration from the
	# copy; a normal "install the running system" keeps everything.
	local HOSTNAME="${ZIGNOS_HOSTNAME:-}"
	local LOCALE="${ZIGNOS_LOCALE:-}"
	local KEYMAP="${ZIGNOS_KEYMAP:-}"
	local TZ="${ZIGNOS_TIMEZONE:-}"
	if [ "$LIVE" = 1 ] && [ -z "$HOSTNAME" ]; then
		HOSTNAME=zignos
	fi
	for c in sfdisk mkfs.ext4 blkid grub-install; do
		command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
	done
	if [ "$UEFI" = 1 ]; then
		for c in mkfs.vfat grub-mkstandalone; do
			command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
		done
		# grub's USE flags select the platforms it was built for.
		[ -d /usr/lib/grub/x86_64-efi ] ||
			die "grub has no x86_64-efi platform (zpkg use --package grub uefi && zpkg install -f grub)"
	else
		[ -d /usr/lib/grub/i386-pc ] ||
			die "grub has no i386-pc platform (zpkg use --package grub bios && zpkg install -f grub)"
	fi

	log "Installing ZIGNOS onto $DISK — ALL DATA ON IT WILL BE DESTROYED"
	if [ "$YES" != 1 ]; then
		read -r -p "Type YES to continue: " answer
		[ "$answer" = YES ] || die "aborted"
	fi

	# NVMe and eMMC devices use a "p" separator (nvme0n1p1), SATA/virtio
	# do not (sda1, vda1).
	local psep=""
	case "$DISK" in
		*[0-9]) psep="p" ;;
	esac
	local part esp=""
	if [ "$UEFI" = 1 ]; then
		log "partitioning $DISK (GPT: 512MiB ESP + ext4 root) — ALL DATA IS DESTROYED"
		sfdisk "$DISK" <<'SFDISK'
label: gpt
start=2048, size=1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ZIGNOS ESP"
start=1050624, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="zignos-root"
SFDISK
		partx -u "$DISK" 2>/dev/null || true
		sleep 1
		esp="${DISK}${psep}1"
		part="${DISK}${psep}2"
		log "creating the EFI system partition (FAT32)"
		mkfs.vfat -F32 -n ZIGNOSESP "$esp"
	else
		log "partitioning $DISK (MBR, one bootable ext4 partition) — ALL DATA IS DESTROYED"
		sfdisk "$DISK" <<'SFDISK'
label: dos
start=2048, type=83, bootable
SFDISK
		partx -u "$DISK" 2>/dev/null || true
		sleep 1
		part="${DISK}${psep}1"
	fi

	log "creating filesystem (label zignos-root)"
	# GRUB 2.14 can't read ext4 with orphan_file/metadata_csum_seed.
	mkfs.ext4 -F -q -O ^orphan_file,^metadata_csum_seed -L zignos-root "$part"
	# The initramfs resolves root=UUID= with busybox blkid.
	local rootuuid espuuid=""
	rootuuid=$(blkid -s UUID -o value "$part" || true)
	[ -n "$rootuuid" ] || die "cannot read the root filesystem UUID"
	if [ "$UEFI" = 1 ]; then
		espuuid=$(blkid -s UUID -o value "$esp" || true)
		[ -n "$espuuid" ] || die "cannot read the ESP filesystem UUID"
	fi

	local mnt
	mnt=$(mktemp -d)
	mount "$part" "$mnt"
	if [ "$UEFI" = 1 ]; then
		mkdir -p "$mnt/boot/efi"
		mount "$esp" "$mnt/boot/efi"
	fi

	log "copying the running system"
	# Same copy profile as make-image.sh: keep the system, drop runtime
	# mounts' contents, caches and seed state (recreated below). A Live ISO
	# additionally drops its session state so the target gets a clean
	# installed system.
	local -a excludes=(
		--exclude='./dev/*'
		--exclude='./proc/*'
		--exclude='./sys/*'
		--exclude='./run/*'
		--exclude='./tmp/*'
		--exclude='./var/cache/zpkg/*'
		--exclude='./var/lib/seedrng/*'
		--exclude='./sources'
	)
	if [ "$LIVE" = 1 ]; then
		excludes+=(
			--exclude='./home/live'
			--exclude='./root/.ssh'
			--exclude='./etc/sddm.conf.d/20-live-autologin.conf'
			--exclude='./var/lib/NetworkManager/*'
			--exclude='./var/lib/sddm/*'
			--exclude='./var/log/*'
		)
	fi
	tar -C / "${excludes[@]}" -cf - . | tar -C "$mnt" -xf -

	log "fixing the usr-merge layout and mount points"
	mkdir -pv "$mnt"/usr/{bin,lib,sbin} "$mnt"/{dev,proc,sys,run,tmp} "$mnt/var/tmp" "$mnt/var/lib/seedrng"
	for s in bin lib sbin; do
		if [ -L "$mnt/$s" ]; then
			ln -sfn "usr/$s" "$mnt/$s"
		elif [ -d "$mnt/$s" ]; then
			# Merge instead of dropping: packages may install into /sbin.
			merge_dir "$mnt/$s" "$mnt/usr/$s"
			rm -rf "${mnt:?}/$s"
			ln -s "usr/$s" "${mnt:?}/$s"
		else
			ln -s "usr/$s" "${mnt:?}/$s"
		fi
	done
	if [ -d "$mnt/lib64" ] && [ ! -L "$mnt/lib64" ]; then
		merge_dir "$mnt/lib64" "$mnt/lib"
		rm -rf "${mnt:?}/lib64"
	fi
	ln -sfn lib "$mnt/lib64"
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"
	rm -f "$mnt/sbin/sbin" "$mnt/usr/sbin/sbin"

	if [ "$LIVE" = 1 ]; then
		log "removing live-only configuration from the target"
		# Drop the live account and its group memberships before useradd
		# allocates UID 1000 for the real user. Field-preserving awk is
		# required: a plain sed ':live$' would turn gshadow's
		#   wheel:!::live
		# into wheel:!: (3 fields, invalid) and useradd would then report
		# that the wheel group does not exist.
		local f
		for f in passwd shadow subuid subgid; do
			[ -f "$mnt/etc/$f" ] || continue
			sed -i '/^live:/d' "$mnt/etc/$f"
		done
		if [ -f "$mnt/etc/group" ]; then
			awk -F: 'BEGIN{OFS=":"}
				$1=="live" { next }
				{
					if (NF>=4) {
						n=split($4,a,","); out=""
						for(i=1;i<=n;i++)
							if(a[i]!="live" && a[i]!="")
								out=out (out?",":"") a[i]
						$4=out
					}
					print
				}' "$mnt/etc/group" > "$mnt/etc/group.new"
			mv "$mnt/etc/group.new" "$mnt/etc/group"
		fi
		if [ -f "$mnt/etc/gshadow" ]; then
			awk -F: 'BEGIN{OFS=":"}
				$1=="live" { next }
				{
					if (NF>=3) {
						n=split($3,a,","); out=""
						for(i=1;i<=n;i++)
							if(a[i]!="live" && a[i]!="")
								out=out (out?",":"") a[i]
						$3=out
					}
					if (NF>=4) {
						n=split($4,b,","); out=""
						for(i=1;i<=n;i++)
							if(b[i]!="live" && b[i]!="")
								out=out (out?",":"") b[i]
						$4=out
					}
					print
				}' "$mnt/etc/gshadow" > "$mnt/etc/gshadow.new"
			mv "$mnt/etc/gshadow.new" "$mnt/etc/gshadow"
		fi
		rm -rf "$mnt/home/live"
		# Stale backups would still name the live account / empty root.
		rm -f "$mnt/etc/passwd-" "$mnt/etc/shadow-" "$mnt/etc/group-" \
			"$mnt/etc/gshadow-"
		rm -f "$mnt/etc/sddm.conf.d/20-live-autologin.conf"
		rm -f "$mnt/usr/sbin/zignos-installer" \
			"$mnt/usr/share/applications/zignos-installer.desktop"
		rm -f "$mnt/var/spool/mail/live" "$mnt/var/mail/live"
		# The live medium logs root in without a password on the serial
		# console; the installed system uses a normal login instead.
		sed -i 's/--autologin root //' "$mnt/etc/init.d/console"
		# The live root does not need to mount/fsck its own root, so the
		# sanitizer removed these from the boot runlevel. An installed
		# system does need them, or / stays read-only.
		local s
		mkdir -p "$mnt/etc/runlevels/boot"
		for s in root root-rw fsck; do
			if [ -x "$mnt/etc/init.d/$s" ]; then
				ln -sfn "/etc/init.d/$s" "$mnt/etc/runlevels/boot/$s"
			fi
		done
		printf 'permit persist :wheel\n' > "$mnt/etc/doas.conf"
		# Empty root password (live default) must not survive the install:
		# root is locked and administration goes through doas/wheel.
		sed -i 's/^root:[^:]*:/root:!:/' "$mnt/etc/shadow"
		# A new machine-id and a non-live identity.
		local mid
		mid=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
		printf '%s\n' "$mid" > "$mnt/etc/machine-id"
		mkdir -p "$mnt/var/lib/dbus"
		printf '%s\n' "$mid" > "$mnt/var/lib/dbus/machine-id"
		local ver channel pretty
		ver=$(sed -n 's/^VERSION_ID=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' /etc/os-release | head -n1)
		channel=$(sed -n 's/^CHANNEL=["]\{0,1\}\([^"]*\)["]\{0,1\}$/\1/p' /etc/zpkg/make.conf 2>/dev/null | head -n1)
		[ -n "$ver" ] || ver=unknown
		[ -n "$channel" ] || channel=stable
		if [ "$channel" = stable ]; then pretty="ZIGNOS $ver"; else pretty="ZIGNOS $ver ($channel)"; fi
		cat > "$mnt/etc/os-release" <<EOF
NAME="ZIGNOS"
PRETTY_NAME="$pretty"
ID=zignos
VERSION_ID="$ver"
VERSION="$pretty"
VERSION_CODENAME=$channel
ANSI_COLOR="38;2;124;92;255"
HOME_URL="https://studio-nosa-tech.github.io/"
BUG_REPORT_URL="https://github.com/studio-nosa-tech/zignos/issues"
LOGO=zignos
EOF
		cat > "$mnt/etc/zignos-release" <<EOF
NAME="ZIGNOS"
PRETTY_NAME="$pretty"
ID=zignos
VERSION_ID="$ver"
VERSION_CODENAME=$channel
EOF
		cat > "$mnt/etc/motd" <<EOF
Welcome to $pretty

  zpkg        package manager (channel in /etc/zpkg/make.conf)
  doas        root commands (wheel)
  rc-service  OpenRC services

Documentation: https://studio-nosa-tech.github.io/docs/
EOF
		# NetworkManager owns resolv.conf on the installed system.
		printf '# Managed by NetworkManager\n' > "$mnt/etc/resolv.conf"
	fi

	if [ -n "$HOSTNAME" ]; then
		log "setting hostname to $HOSTNAME"
		printf '%s\n' "$HOSTNAME" > "$mnt/etc/hostname"
		mkdir -p "$mnt/etc/conf.d"
		printf 'hostname="%s"\n' "$HOSTNAME" > "$mnt/etc/conf.d/hostname"
		cat > "$mnt/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$HOSTNAME
EOF
	fi
	if [ -n "$LOCALE" ]; then
		# locale -a prints ja_JP.utf8; compare base names case- and
		# hyphen-insensitively against the requested ja_JP.UTF-8.
		if ! chroot "$mnt" locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' |
			grep -qx "$(printf '%s' "$LOCALE" | tr '[:upper:]' '[:lower:]' | tr -d '-')"; then
			die "locale $LOCALE is not installed in the target"
		fi
		log "setting locale to $LOCALE"
		printf 'LANG=%s\n' "$LOCALE" > "$mnt/etc/locale.conf"
	fi
	if [ -n "$TZ" ]; then
		[ -e "$mnt/usr/share/zoneinfo/$TZ" ] || die "unknown timezone: $TZ"
		log "setting timezone to $TZ"
		ln -sfn "/usr/share/zoneinfo/$TZ" "$mnt/etc/localtime"
		printf '%s\n' "$TZ" > "$mnt/etc/timezone"
	fi
	if [ -n "$KEYMAP" ]; then
		log "setting console keymap to $KEYMAP"
		mkdir -p "$mnt/etc/conf.d"
		if [ -f "$mnt/etc/conf.d/keymaps" ]; then
			sed -i "s/^keymap=.*/keymap=\"$KEYMAP\"/" "$mnt/etc/conf.d/keymaps"
		else
			printf 'keymap="%s"\n' "$KEYMAP" > "$mnt/etc/conf.d/keymaps"
		fi
		printf 'KEYMAP=%s\n' "$KEYMAP" > "$mnt/etc/vconsole.conf"
	fi

	log "creating the user account"
	local user pass
	user="${ZIGNOS_USER:-}"
	pass="${ZIGNOS_PASSWORD:-}"
	if [ "$YES" = 1 ]; then
		user="${user:-zignos}"
		pass="${pass:-zignos}"
		echo "zignos-install: creating user '$user' (ZIGNOS_USER/ZIGNOS_PASSWORD override)"
	else
		[ -n "$user" ] || read -r -p "Username [zignos]: " user
		[ -n "$user" ] || user=zignos
		if [ -z "$pass" ]; then
			local p1 p2
			while :; do
				read -r -s -p "Password for $user: " p1; echo
				read -r -s -p "Repeat password: " p2; echo
				[ -n "$p1" ] && [ "$p1" = "$p2" ] && break
				echo "empty or mismatched password, try again" >&2
			done
			pass="$p1"
		fi
	fi
	# chpasswd splits on ':', and a newline would end the record early.
	case "$pass" in
		*:*|*$'\n'*) die "password must not contain ':' or a newline" ;;
	esac
	# The single-quoted script runs inside the target chroot, so $1 is
	# expanded there (not by this shell).
	# shellcheck disable=SC2016
	chroot "$mnt" /bin/bash -c '
		set -e
		command -v useradd >/dev/null 2>&1
		getent group wheel >/dev/null || groupadd -g 10 wheel
		groups=wheel
		for g in audio video render input; do
			getent group "$g" >/dev/null 2>&1 && groups="$groups,$g"
		done
		id -u "$1" >/dev/null 2>&1 || useradd -m -G "$groups" -s /bin/bash "$1"
	' _ "$user"
	printf '%s:%s\n' "$user" "$pass" | chroot "$mnt" chpasswd

	# SSH key for the new user: reuse root's authorized_keys (the usual
	# "install from the machine you administer" flow); interactive mode
	# also allows pasting one when root has no keys.
	log "installing SSH authorized_keys for $user"
	local keys=""
	if [ -s /root/.ssh/authorized_keys ]; then
		keys=/root/.ssh/authorized_keys
	elif [ "$YES" != 1 ]; then
		local key=""
		echo "Paste an SSH public key for $user (empty to skip):"
		read -r key || key=""
		if [ -n "$key" ]; then
			mkdir -p /tmp/zignos-install-key
			printf '%s\n' "$key" > /tmp/zignos-install-key/authorized_keys
			keys=/tmp/zignos-install-key/authorized_keys
		fi
	fi
	if [ -n "$keys" ]; then
		local uid gid
		uid=$(chroot "$mnt" id -u "$user")
		gid=$(chroot "$mnt" id -g "$user")
		install -d -m 700 -o "$uid" -g "$gid" "$mnt/home/$user/.ssh"
		install -m 600 -o "$uid" -g "$gid" "$keys" "$mnt/home/$user/.ssh/authorized_keys"
		echo "installed authorized_keys for $user"
	else
		echo "no SSH key installed for $user (password login only)"
	fi

	log "writing /etc/fstab (UUID-based)"
	# The initramfs mounts / read-only; OpenRC remounts it rw. A boot-time
	# fsck cannot run on a busy root, so pass 0 keeps the fsck service away.
	printf 'UUID=%s / ext4 defaults 0 0\n' "$rootuuid" > "$mnt/etc/fstab"
	if [ "$UEFI" = 1 ]; then
		printf 'UUID=%s /boot/efi vfat defaults 0 2\n' "$espuuid" >> "$mnt/etc/fstab"
	fi
	printf 'proc /proc proc defaults 0 0\n' >> "$mnt/etc/fstab"
	printf 'sysfs /sys sysfs defaults 0 0\n' >> "$mnt/etc/fstab"

	log "copying the kernel and initramfs into the target /boot"
	mkdir -pv "$mnt/boot"
	cp -a /boot/vmlinuz* "$mnt/boot/" 2>/dev/null || true
	cp -a /boot/initramfs.img "$mnt/boot/initramfs.img"
	[ -f "$mnt/boot/initramfs.img" ] ||
		die "the running system has no /boot/initramfs.img - rebuild the linux recipe"

	# grub.cfg shared by both firmwares: BIOS reads it from /boot/grub,
	# UEFI has the same text embedded in BOOTX64.EFI by grub-mkstandalone.
	local grubcfg="$mnt/tmp/zignos-grub.cfg"
	cat > "$grubcfg" <<GRUBCFG
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console
set timeout=5
set default=0
search --no-floppy --fs-uuid --set=root $rootuuid
menuentry "ZIGNOS" {
	linux /boot/vmlinuz root=UUID=$rootuuid console=tty0 console=ttyS0
	initrd /boot/initramfs.img
}
GRUBCFG
	mkdir -pv "$mnt/boot/grub"
	cp "$grubcfg" "$mnt/boot/grub/grub.cfg"

	log "installing GRUB ($([ "$UEFI" = 1 ] && echo UEFI || echo BIOS))"
	mkdir -pv "$mnt"/{dev,proc,sys}
	mount --bind /dev "$mnt/dev"
	mount -vt proc proc "$mnt/proc"
	mount -vt sysfs sysfs "$mnt/sys"
	if [ "$UEFI" = 1 ]; then
		# Removable path (/EFI/BOOT/BOOTX64.EFI): firmware on any machine
		# finds this file, so booting does not depend on NVRAM.
		mkdir -p "$mnt/boot/efi/EFI/BOOT"
		chroot "$mnt" grub-mkstandalone -O x86_64-efi \
			-o /boot/efi/EFI/BOOT/BOOTX64.EFI \
			--modules="part_gpt part_msdos fat ext2 normal search search_fs_uuid linux echo serial terminal" \
			"boot/grub/grub.cfg=/tmp/zignos-grub.cfg"
		echo "UEFI: wrote /boot/efi/EFI/BOOT/BOOTX64.EFI (firmware fallback path)"
		# efibootmgr lives in main/ and is not part of the minimal base.
		# When the running image has it, register a proper NVRAM entry too;
		# the removable path above keeps the install bootable either way.
		if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi/efivars ]; then
			if efibootmgr --create --disk "$DISK" --part 1 \
				--label ZIGNOS --loader '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1; then
				echo "UEFI: registered a ZIGNOS boot entry (efibootmgr)"
			else
				echo "UEFI: efibootmgr could not add an entry (firmware may be read-only)"
			fi
		fi
	else
		# The chroot IS the target partition, so grub-install probes the
		# target /boot directly and embeds its search (no loop ambiguity).
		chroot "$mnt" grub-install --target=i386-pc --boot-directory=/boot "$DISK"
	fi
	umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true
	rm -f "$grubcfg"

	log "recreating runtime mount points in the image"
	umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true
	mkdir -pv "$mnt"/{dev,proc,sys,run,tmp} "$mnt/var/tmp" "$mnt/var/lib/seedrng"
	chmod 1777 "$mnt/tmp" "$mnt/var/tmp"

	if [ "$UEFI" = 1 ]; then
		umount "$mnt/boot/efi"
	fi
	local has_sshd=0
	[ -x "$mnt/usr/sbin/sshd" ] && has_sshd=1
	umount "$mnt"
	rmdir "$mnt" 2>/dev/null || true

	log "done — ZIGNOS-INSTALL-COMPLETE"
	echo "Boot from $DISK and log in as $user."
	if [ "$LIVE" = 1 ]; then
		echo "root is locked; use 'doas' (wheel) for administrative commands."
	fi
	if [ "$has_sshd" = 1 ]; then
		echo "SSH: ssh $user@<host>  (root SSH login is disabled)"
	else
		echo "SSH is not part of the minimal base: zpkg install openssh && rc-update add sshd default"
	fi
}

main "$@"
