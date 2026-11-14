#!/bin/bash
# ZIGNOS bootstrap orchestrator.
#
# Builds the ZIGNOS base system on a build VM:
#   stage0 (lfs user)    — stage0.sh: LFS 13.1-systemd ch4/ch5/ch6, i.e. the
#                          cross toolchain + cross-compiled temporary tools
#   stage1 (root/chroot) — stage1.sh: ch7 directories, essential files,
#                          additional temporary tools (gettext, perl, python,
#                          util-linux, ninja, meson) + ZIGNOS scaffolding
#                          (Go bootstrap toolchain)
#   stage2 (chroot)      — stage2.sh: zpkg builds the final system from the
#                          core recipes, ending with zpkg self-hosting
#
# Reference: LFS 13.1-systemd (https://www.linuxfromscratch.org/lfs/view/13.1-systemd/).
# Deliberate deviations for ZIGNOS: no systemd stack, stage2 driven by zpkg
# recipes with tests skipped, Go bootstrapped from the official binary then
# rebuilt from source as a package.
#
# Run as root on the build VM with a clean ext4 partition mounted at $LFS.
# Host prerequisites: see zignos/docs/env.md.

set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
LFS_TGT="$(uname -m)-lfs-linux-gnu"
JOBS="${JOBS:-$(nproc)}"
ZIGNOS_DIR="${ZIGNOS_DIR:-$HOME/zignos}"
ZIGNOS_RECIPES="${ZIGNOS_RECIPES:-$ZIGNOS_DIR/zignos-recipes}"
ZIGNOS_ZPKG_SRC="${ZIGNOS_ZPKG_SRC:-$ZIGNOS_DIR/zpkg}"
ZIGNOS_BUILD="$(cd "$(dirname "$0")" && pwd)"
SRC="$LFS/sources"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mbootstrap: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# LFS 13.1-systemd sources: url|filename|hash ("~" prefix = sha256, else md5)
# ---------------------------------------------------------------------------
SOURCES_LIST='
https://ftpmirror.gnu.org/binutils/binutils-2.47.tar.xz|binutils-2.47.tar.xz|d772acfbd55a81644e9fe7b8189cd2a5
https://ftpmirror.gnu.org/gcc/gcc-16.2.0/gcc-16.2.0.tar.xz|gcc-16.2.0.tar.xz|19b777fb19ea4982731392481306f0d3
https://ftpmirror.gnu.org/gmp/gmp-6.3.0.tar.xz|gmp-6.3.0.tar.xz|956dc04e864001a9c22429f761f2c283
https://ftpmirror.gnu.org/mpfr/mpfr-4.2.2.tar.xz|mpfr-4.2.2.tar.xz|7c32c39b8b6e3ae85f25156228156061
https://ftpmirror.gnu.org/mpc/mpc-1.4.1.tar.xz|mpc-1.4.1.tar.xz|40c5fba305125279ea46041160e81daf
https://www.kernel.org/pub/linux/kernel/v7.x/linux-7.1.8.tar.xz|linux-7.1.8.tar.xz|807584f564568b40162e9e4a72bf191f
https://ftpmirror.gnu.org/glibc/glibc-2.44.tar.xz|glibc-2.44.tar.xz|7677da43ef759c68e005f5d4c37986a6
https://www.linuxfromscratch.org/patches/lfs/13.1/glibc-fhs-1.patch|glibc-fhs-1.patch|9a5997c3452909b1769918c759eff8a2
https://www.linuxfromscratch.org/patches/lfs/13.1/glibc-2.44-upstream_fixes-1.patch|glibc-2.44-upstream_fixes-1.patch|990574184b25aa3029a2444e81865098
https://ftpmirror.gnu.org/m4/m4-1.4.21.tar.xz|m4-1.4.21.tar.xz|8051eef7239b2f187791f2ab0034d6b7
https://invisible-mirror.net/archives/ncurses/ncurses-6.6.tar.gz|ncurses-6.6.tar.gz|dd45bf6854430af403452a7a6a40652c
https://ftpmirror.gnu.org/bash/bash-5.3.tar.gz|bash-5.3.tar.gz|977c8c0c5ae6309191e7768e28ebc951
https://ftpmirror.gnu.org/coreutils/coreutils-9.11.tar.xz|coreutils-9.11.tar.xz|e52e9857e4aa9ae38ef32f8ed6a27604
https://ftpmirror.gnu.org/diffutils/diffutils-3.12.tar.xz|diffutils-3.12.tar.xz|d1b18b20868fb561f77861cd90b05de4
https://astron.com/pub/file/file-5.48.tar.gz|file-5.48.tar.gz|423686e97f731d8c24e9cd1a22b03dec
https://ftpmirror.gnu.org/findutils/findutils-4.11.0.tar.xz|findutils-4.11.0.tar.xz|512c6875ed84034dca240c4bc9380b96
https://ftpmirror.gnu.org/gawk/gawk-5.4.1.tar.xz|gawk-5.4.1.tar.xz|d379c2110e7a3e15347dd5559a41ad64
https://ftpmirror.gnu.org/grep/grep-3.12.tar.xz|grep-3.12.tar.xz|5d9301ed9d209c4a88c8d3a6fd08b9ac
https://ftpmirror.gnu.org/gzip/gzip-1.14.tar.xz|gzip-1.14.tar.xz|4bf5a10f287501ee8e8ebe00ef62b2c2
https://ftpmirror.gnu.org/make/make-4.4.1.tar.gz|make-4.4.1.tar.gz|c8469a3713cbbe04d955d4ae4be23eeb
https://ftpmirror.gnu.org/patch/patch-2.8.tar.xz|patch-2.8.tar.xz|149327a021d41c8f88d034eab41c039f
https://ftpmirror.gnu.org/sed/sed-4.10.tar.xz|sed-4.10.tar.xz|c70dc5372db95c816442ffedf77a0d0f
https://ftpmirror.gnu.org/tar/tar-1.35.tar.xz|tar-1.35.tar.xz|a2d8042658cfd8ea939e6d911eaf4152
https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.xz|xz-5.8.3.tar.xz|a02753f34e5546d20213b87f876a0933
https://ftpmirror.gnu.org/gettext/gettext-1.0.tar.xz|gettext-1.0.tar.xz|dc8b2911535929cec1e263706b0a13a1
https://ftpmirror.gnu.org/bison/bison-3.8.2.tar.xz|bison-3.8.2.tar.xz|c28f119f405a2304ff0a7ccdcc629713
https://www.cpan.org/src/5.0/perl-5.44.0.tar.xz|perl-5.44.0.tar.xz|55761cf1543af326492fd194647796d1
https://zlib.net/fossils/zlib-1.3.2.tar.gz|zlib-1.3.2.tar.gz|a1e6c958597af3c67d162995a342138a
https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-4.0.1.tar.gz|mpdecimal-4.0.1.tar.gz|3d4412579b1edc1047efab151889cca9
https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tar.xz|Python-3.14.7.tar.xz|a4c4c2991b4126e227073c2d9445f432
https://ftpmirror.gnu.org/texinfo/texinfo-7.3.tar.xz|texinfo-7.3.tar.xz|915a09fcdfc2bf0f5ecf9e556d5698ff
https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.2.tar.xz|util-linux-2.42.2.tar.xz|1d70131b70abda3dec3b37e282a20c96
https://www.sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz|bzip2-1.0.8.tar.gz|67e051268d0c475ea773822f7500d0e5
https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz|zstd-1.5.7.tar.gz|780fc1896922b1bc52a4e90980cdda48
https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2|pcre2-10.47.tar.bz2|aded5840ab5a7d772dd4e16fc294b665
https://ftpmirror.gnu.org/readline/readline-8.3.tar.gz|readline-8.3.tar.gz|25a73bfb2a3ad7146c5e9d4408d9f6cd
https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz|flex-2.6.4.tar.gz|2882e3179748cc9f9c23ec593d6adc8d
https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.5.tar.xz|pkgconf-3.0.5.tar.xz|18c528161e6b04ae36dc981af8c4d97e
https://github.com/ninja-build/ninja/archive/v1.13.2/ninja-1.13.2.tar.gz|ninja-1.13.2.tar.gz|76c00637fde44909cd7d56f8d73f2042
https://github.com/mesonbuild/meson/releases/download/1.12.0/meson-1.12.0.tar.gz|meson-1.12.0.tar.gz|9f943c267d63016012efcb0f31ecdd7d
https://go.dev/dl/go1.27.4.src.tar.gz|go1.27.4.src.tar.gz|~73cfb8571aec0c01177687db87163d46aa20e9779672772891aa17654d9a6099
https://go.dev/dl/go1.27.4.linux-amd64.tar.gz|go1.27.4.linux-amd64.tar.gz|~7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
'

preflight() {
	log "preflight"
	[ "$(id -u)" = 0 ] || die "run as root"
	mountpoint -q "$LFS" || die "$LFS is not a mountpoint (format+mount a clean partition first)"
	for c in gcc g++ make gawk makeinfo bison perl python3 curl wget tar gzip xz bzip2 file patch diff go; do
		command -v "$c" >/dev/null 2>&1 || die "missing host tool: $c"
	done
	[ -d "$ZIGNOS_RECIPES/core" ] || die "recipe tree not found: $ZIGNOS_RECIPES"
	[ -f "$ZIGNOS_ZPKG_SRC/go.mod" ] || die "zpkg source not found: $ZIGNOS_ZPKG_SRC"
	if [ -e /etc/bash.bashrc ]; then mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE; fi
	umask 022
	export LFS LFS_TGT JOBS
}

sources_fetch() {
	log "ch3: sources ($SRC)"
	mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
	for i in bin lib sbin; do ln -sv usr/"$i" "$LFS/$i"; done
	case "$(uname -m)" in x86_64) mkdir -pv "$LFS/lib64" ;; esac
	mkdir -pv "$LFS/tools" "$SRC" "$LFS/tmp"
	chmod -v a+wt "$SRC"

	local url fn hash
	while IFS='|' read -r url fn hash; do
		[ -n "$url" ] || continue
		if [ ! -s "$SRC/$fn" ]; then
			log "  fetch $fn"
			curl -fSL --retry 3 --retry-delay 5 -o "$SRC/$fn" "$url"
		fi
		if [ "${hash:0:1}" = "~" ]; then
			echo "${hash:1}  $fn" | (cd "$SRC" && sha256sum -c -)
		else
			echo "$hash  $fn" | (cd "$SRC" && md5sum -c --status -) \
				|| die "md5 mismatch: $fn"
		fi
	done <<< "$SOURCES_LIST"
}

prepare_lfs_user() {
	log "ch4: lfs user"
	id lfs >/dev/null 2>&1 || {
		groupadd lfs
		useradd -s /bin/bash -g lfs -m -k /dev/null lfs
	}
	chown -v lfs "$LFS"/{usr{,/*},var,etc,tools}
	case "$(uname -m)" in x86_64) chown -v lfs "$LFS/lib64" ;; esac
	chown -v lfs "$SRC"

	# ch4.4: clean environment for the lfs user (bash_profile execs env -i).
	cat > /home/lfs/.bash_profile <<'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF
	# The .bashrc is for interactive logins; stage0.sh sets its own env.
	chown lfs:lfs /home/lfs/.bash_profile
}

mount_vfs() {
	log "7.3 virtual kernel file systems"
	mkdir -pv "$LFS"/{dev,proc,sys,run}
	mount -v --bind /dev "$LFS/dev"
	mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
	mount -vt proc proc "$LFS/proc"
	mount -vt sysfs sysfs "$LFS/sys"
	mount -vt tmpfs tmpfs "$LFS/run"
	if [ -h "$LFS/dev/shm" ]; then
		install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
	else
		mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
	fi
}

unmount_vfs() {
	mountpoint -q "$LFS/dev/shm" && umount "$LFS/dev/shm" || true
	mountpoint -q "$LFS/dev/pts" && umount "$LFS/dev/pts" || true
	umount "$LFS"/{sys,proc,run,dev} 2>/dev/null || true
}

chroot_run() {
	# 7.4: enter the chroot with a clean environment; /tools not in PATH.
	chroot "$LFS" /usr/bin/env -i \
		HOME=/root TERM="${TERM:-linux}" \
		PS1='(zignos) \u:\w\$ ' \
		PATH=/usr/bin:/usr/sbin \
		MAKEFLAGS="-j$JOBS" \
		/bin/bash "/tmp/$1"
}

scaffold() {
	log "stage1 scaffold: zpkg + recipes + source cache"
	# Static zpkg, built with the host Go toolchain.
	(cd "$ZIGNOS_ZPKG_SRC" && CGO_ENABLED=0 go build -o "$LFS/usr/bin/zpkg" ./cmd/zpkg)
	# Recipe tree and zpkg source snapshot for self-hosting.
	rm -rf "$LFS/sources/zignos-recipes" "$LFS/sources/zignos-zpkg"
	cp -a "$ZIGNOS_RECIPES" "$LFS/sources/zignos-recipes"
	cp -a "$ZIGNOS_ZPKG_SRC" "$LFS/sources/zignos-zpkg"
	# Seed the zpkg source cache so stage2 recipes verify local files
	# (sha256) instead of re-downloading.
	mkdir -p "$LFS/var/cache/zpkg"
	find "$SRC" -maxdepth 1 -type f -exec cp -a {} "$LFS/var/cache/zpkg/" \;
}

run_stage() {
	# $1 = stage script name in the zignos-build checkout.
	local script="$1"
	mkdir -p "$LFS/tmp"
	cp "$ZIGNOS_BUILD/$script" "$LFS/tmp/$script"
	chmod +x "$LFS/tmp/$script"
	chroot_run "$script"
}

main() {
	preflight
	sources_fetch
	prepare_lfs_user

	log "stage0: ch5+ch6 as lfs user"
	install -m 644 "$ZIGNOS_BUILD/stage0.sh" "$LFS/tmp/stage0.sh"
	su -s /bin/bash lfs -c "LFS=$LFS LFS_TGT=$LFS_TGT MAKEFLAGS=-j$JOBS bash $LFS/tmp/stage0.sh"

	log "7.2 changing ownership"
	chown --from lfs -R root:root "$LFS"/{usr,var,etc,tools}
	case "$(uname -m)" in x86_64) chown --from lfs -R root:root "$LFS/lib64" ;; esac

	mount_vfs
	run_stage stage1.sh
	scaffold
	run_stage stage2.sh
	unmount_vfs

	log "bootstrap complete: ZIGNOS base system at $LFS"
}

main "$@"
