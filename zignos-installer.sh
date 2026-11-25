#!/bin/bash
# ZIGNOS installer — whiptail front-end for zignos-install.
#
# Run as root (on the Live ISO: `doas zignos-installer`, or the
# "Install ZIGNOS" entry in the application menu). It asks for the target
# disk, firmware mode, hostname and user, then hands the answers to
# /usr/sbin/zignos-install. Every byte on the chosen disk is destroyed.
#
# Usage:
#   zignos-installer [--auto] [/dev/sdX]
#
# --auto skips the menus and uses ZIGNOS_* environment variables (used for
# unattended testing); /dev/sdX is then required.

set -euo pipefail

TITLE="ZIGNOS Installer"
LOG=/var/log/zignos-install.log
ENGINE=/usr/sbin/zignos-install

die() { printf 'zignos-installer: %s\n' "$*" >&2; exit 1; }
msg() { whiptail --title "$TITLE" --msgbox "$*" 12 70; }
ask() { whiptail "$@" 3>&1 1>&2 2>&3; }

# If the front-end is interrupted, stop the installer instead of letting it
# keep partitioning/copying in the background.
ENGINE_PID=""
cleanup() {
	if [ -n "$ENGINE_PID" ]; then
		kill "$ENGINE_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

AUTO=0
if [ "${1:-}" = "--auto" ]; then
	AUTO=1
	shift
fi
DISK="${1:-${ZIGNOS_DISK:-}}"

[ "$(id -u)" = 0 ] || die "run as root (doas zignos-installer)"
command -v whiptail >/dev/null 2>&1 || die "whiptail is not installed"
[ -x "$ENGINE" ] || die "$ENGINE is missing"

# The medium we booted from must never be offered as an install target.
live_disk() {
	local src parent
	src=$(findmnt -n -o SOURCE /run/iso 2>/dev/null | head -n1) || true
	[ -n "$src" ] || return 0
	parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1) || true
	if [ -n "$parent" ]; then
		printf '/dev/%s\n' "$parent"
	else
		printf '%s\n' "$src"
	fi
}

run_engine() {
	export ZIGNOS_FIRMWARE="$FIRMWARE"
	export ZIGNOS_HOSTNAME="$HOSTNAME"
	export ZIGNOS_USER="$USERNAME"
	export ZIGNOS_PASSWORD="$PASSWORD"
	export ZIGNOS_LOCALE="$LOCALE"
	export ZIGNOS_KEYMAP="$KEYMAP"
	export ZIGNOS_TIMEZONE="$TIMEZONE"

	: > "$LOG"
	"$ENGINE" --yes "$DISK" </dev/null >>"$LOG" 2>&1 &
	local pid=$!
	ENGINE_PID=$pid
	local start
	start=$(date +%s)
	(
		local spin='-\|/' i=0 mnt total used pct=0 last now elapsed
		while kill -0 "$pid" 2>/dev/null; do
			mnt=$(cat /run/zignos-install.mnt 2>/dev/null || true)
			total=$(cat /run/zignos-install.total 2>/dev/null || true)
			case "$total" in
				''|*[!0-9]*) total=0 ;;
			esac
			if [ -n "$mnt" ] && [ "$total" -gt 0 ]; then
				# Keep the last percentage if the target is already
				# unmounted at the end of the install.
				used=$(df -B1 --output=used "$mnt" 2>/dev/null |
					tail -n1 | tr -dc '0-9') || true
				case "$used" in
					''|*[!0-9]*) used=0 ;;
				esac
				if [ "$used" -gt 0 ]; then
					pct=$((used * 100 / total))
					[ "$pct" -gt 99 ] && pct=99
				fi
			fi
			now=$(date +%s)
			elapsed=$((now - start))
			last=$(tail -n1 "$LOG" 2>/dev/null |
				tr -d '\r' | cut -c1-68) || true
			i=$(((i + 1) % 4))
			printf '%s\n' "$pct"
			printf 'XXX\n'
			printf 'Installing ZIGNOS on %s\n\n[%c] %ds elapsed\n%s\n\nLog: %s\n' \
				"$DISK" "${spin:$i:1}" "$elapsed" "$last" "$LOG"
			printf 'XXX\n'
			sleep 1
		done
		printf '100\nXXX\nFinishing...\nXXX\n'
	) | whiptail --title "$TITLE" --gauge \
		"Installing ZIGNOS on $DISK..." 15 78 0
	local rc=0
	wait "$pid" || rc=$?
	ENGINE_PID=""
	return "$rc"
}

auto_install() {
	[ -n "$DISK" ] || die "--auto requires a target disk"
	[ -b "$DISK" ] || die "$DISK is not a block device"
	FIRMWARE="${ZIGNOS_FIRMWARE:-auto}"
	HOSTNAME="${ZIGNOS_HOSTNAME:-zignos}"
	USERNAME="${ZIGNOS_USER:-zignos}"
	PASSWORD="${ZIGNOS_PASSWORD:-zignos}"
	LOCALE="${ZIGNOS_LOCALE:-en_US.UTF-8}"
	KEYMAP="${ZIGNOS_KEYMAP:-us}"
	TIMEZONE="${ZIGNOS_TIMEZONE:-UTC}"
	: > "$LOG"
	"$ENGINE" --yes "$DISK" </dev/null 2>&1 | tee -a "$LOG"
	echo "zignos-installer: installation complete (log: $LOG)"
}

if [ "$AUTO" = 1 ]; then
	auto_install
	exit 0
fi

# --- target disk ---------------------------------------------------------
live=$(live_disk)
disk_menu=()
while IFS= read -r d; do
	name=${d##*/}
	[ -b "/dev/$name" ] || continue
	[ "/dev/$name" = "$live" ] && continue
	sectors=$(cat "$d/size" 2>/dev/null) || continue
	[ "${sectors:-0}" -gt 0 ] || continue
	bytes=$((sectors * 512))
	if [ "$bytes" -ge 1073741824 ]; then
		size="$((bytes / 1073741824)) GiB"
	else
		size="$((bytes / 1048576)) MiB"
	fi
	model=$(cat "$d/device/model" 2>/dev/null | sed 's/^ *//;s/ *$//') || true
	disk_menu+=("/dev/$name" "$size${model:+  $model}")
done < <(for d in /sys/block/*; do
	case "${d##*/}" in
		loop*|ram*|zram*|sr*|dm-*|md*) continue ;;
	esac
	printf '%s\n' "$d"
done)

if [ "${#disk_menu[@]}" = 0 ]; then
	msg "No installable disk was found."
	exit 1
fi
if [ -n "$DISK" ]; then
	[ -b "$DISK" ] || die "$DISK is not a block device"
	[ "$DISK" != "$live" ] || die "refusing to install onto the live medium ($DISK)"
else
	DISK=$(ask --title "$TITLE" --menu \
		"Select the disk to install ZIGNOS on.\n\nALL DATA ON THE CHOSEN DISK WILL BE DESTROYED." \
		20 78 10 "${disk_menu[@]}") || exit 0
fi

# --- firmware ------------------------------------------------------------
fw_menu=()
[ -d /usr/lib/grub/x86_64-efi ] && fw_menu+=(uefi "UEFI (GPT + EFI system partition)")
[ -d /usr/lib/grub/i386-pc ] && fw_menu+=(bios "BIOS / legacy (MBR)")
if [ "${#fw_menu[@]}" = 0 ]; then
	die "GRUB has neither the x86_64-efi nor the i386-pc platform installed"
fi
if [ "${#fw_menu[@]}" -ge 4 ]; then
	if [ -d /sys/firmware/efi ]; then default_fw=uefi; else default_fw=bios; fi
	FIRMWARE=$(ask --title "$TITLE" --default-item "$default_fw" --menu \
		"Firmware mode for the installed system:" 14 70 4 "${fw_menu[@]}") || exit 0
else
	FIRMWARE=${fw_menu[0]}
fi

# --- identity ------------------------------------------------------------
while :; do
	HOSTNAME=$(ask --title "$TITLE" --inputbox \
		"Hostname for the new system:" 10 60 "zignos") || exit 0
	case "$HOSTNAME" in
		""|*[!A-Za-z0-9-]*|-*|*-) msg "Use letters, digits and inner hyphens only." ;;
		*) [ "${#HOSTNAME}" -le 63 ] && break; msg "Hostname is too long." ;;
	esac
done

while :; do
	USERNAME=$(ask --title "$TITLE" --inputbox \
		"Username for the new account:" 10 60 "zignos") || exit 0
	case "$USERNAME" in
		""|*[!a-z0-9_-]*) msg "Use lowercase letters, digits, '_' and '-' only." ;;
		root|live) msg "'$USERNAME' is reserved on the Live medium." ;;
		*)
			if [ "${#USERNAME}" -gt 32 ]; then
				msg "Username is too long."
			elif getent passwd "$USERNAME" >/dev/null 2>&1; then
				msg "A user named '$USERNAME' already exists on the Live medium."
			else
				break
			fi
			;;
	esac
done

while :; do
	PASSWORD=$(ask --title "$TITLE" --passwordbox \
		"Password for $USERNAME:" 10 60) || exit 0
	if [ -z "$PASSWORD" ]; then
		msg "The password must not be empty."
		continue
	fi
	case "$PASSWORD" in
		*:*|*$'\n'*) msg "The password must not contain ':' or a newline."; continue ;;
	esac
	PASSWORD2=$(ask --title "$TITLE" --passwordbox \
		"Repeat the password:" 10 60) || exit 0
	[ "$PASSWORD" = "$PASSWORD2" ] && break
	msg "The passwords do not match."
done

# --- regional settings ---------------------------------------------------
tz_menu=(
	Asia/Tokyo "Japan"
	UTC "UTC"
	Asia/Shanghai "China"
	Asia/Seoul "Korea"
	Asia/Kolkata "India"
	Europe/London "United Kingdom"
	Europe/Berlin "Germany"
	Europe/Paris "France"
	America/New_York "US Eastern"
	America/Chicago "US Central"
	America/Los_Angeles "US Pacific"
	Australia/Sydney "Australia"
	OTHER "Enter another zoneinfo name"
)
TIMEZONE=$(ask --title "$TITLE" --default-item Asia/Tokyo --menu \
	"Timezone:" 22 70 13 "${tz_menu[@]}") || exit 0
if [ "$TIMEZONE" = OTHER ]; then
	while :; do
		TIMEZONE=$(ask --title "$TITLE" --inputbox \
			"Timezone name (as in /usr/share/zoneinfo):" 10 60) || exit 0
		[ -e "/usr/share/zoneinfo/$TIMEZONE" ] && break
		msg "No such timezone: $TIMEZONE"
	done
fi

locale_menu=()
while IFS= read -r l; do
	case "$l" in
		*.[Uu][Tt][Ff]8*|*.[Uu][Tt][Ff]-8*)
			l=$(printf '%s' "$l" | sed 's/\.utf-\?8$/.UTF-8/')
			locale_menu+=("$l" "UTF-8 locale")
			;;
	esac
done < <(locale -a 2>/dev/null | sort -u)
if [ "${#locale_menu[@]}" = 0 ]; then
	locale_menu=(en_US.UTF-8 "UTF-8 locale")
fi
default_locale=en_US.UTF-8
for l in "${locale_menu[@]}"; do
	[ "$l" = ja_JP.UTF-8 ] && default_locale=ja_JP.UTF-8
done
LOCALE=$(ask --title "$TITLE" --default-item "$default_locale" --menu \
	"System language / locale:" 20 70 10 "${locale_menu[@]}") || exit 0

keymap_menu=(
	us "US English"
	jp106 "Japanese (106 key)"
	uk "UK English"
	de "German"
	fr "French"
	es "Spanish"
	OTHER "Enter another keymap"
)
KEYMAP=$(ask --title "$TITLE" --default-item us --menu \
	"Console keymap:" 18 70 8 "${keymap_menu[@]}") || exit 0
if [ "$KEYMAP" = OTHER ]; then
	KEYMAP=$(ask --title "$TITLE" --inputbox \
		"Console keymap name (in /usr/share/keymaps):" 10 60 "us") || exit 0
fi

# --- summary -------------------------------------------------------------
summary=$(cat <<EOF
Disk:      $DISK
Firmware:  $FIRMWARE
Hostname:  $HOSTNAME
User:      $USERNAME
Locale:    $LOCALE
Keymap:    $KEYMAP
Timezone:  $TIMEZONE

ALL DATA ON $DISK WILL BE DESTROYED.
This cannot be undone.
EOF
)
whiptail --title "$TITLE" --yesno "$summary" 20 70 || exit 0

if run_engine; then
	whiptail --title "$TITLE" --msgbox \
		"Installation complete.\n\nRemove the Live medium and reboot into the installed system." \
		12 70
else
	whiptail --title "$TITLE" --textbox "$LOG" 24 78 || true
	whiptail --title "$TITLE" --msgbox \
		"Installation failed.\n\nSee $LOG for details." 12 70
	exit 1
fi
