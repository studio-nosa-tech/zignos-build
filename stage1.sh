#!/bin/bash
# ZIGNOS bootstrap stage1 — runs INSIDE the chroot as root.
# LFS 13.1-systemd ch7.5-7.15 (directories, essential files, additional
# temporary tools) plus ZIGNOS scaffolding: ninja, the Go bootstrap
# toolchain. Deliberate deviations: no systemd users/groups.
#
# Copied to /tmp by bootstrap.sh and run via chroot.

set -euo pipefail

log() { printf '\n== %s\n' "$*"; }

# enter <dir> <archive> — extract from /sources and cd in
enter() {
	rm -rf "$1"
	tar -xf "/sources/$2"
	cd "$1"
}

leave() {
	cd /sources
	rm -rf "$1"
}

log "7.5 creating directories"
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/lib/locale
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}
# -n so re-runs replace the symlink itself instead of following it.
ln -sfnv /run /var/run
ln -sfnv /run/lock /var/lock
install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

log "7.6 essential files"
ln -sfv /proc/self/mounts /etc/mtab
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF
cat > /etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:daemon:/dev/null:/usr/bin/false
nobody:x:65534:65534:nobody:/dev/null:/usr/bin/false
EOF
cat > /etc/group <<'EOF'
root:x:0:
bin:x:1:
sys:x:3:
tty:x:5:
daemon:x:6:
disk:x:8:
lp:x:9:
dialout:x:20:
audio:x:29:
video:x:44:
utmp:x:15:
nogroup:x:65534:
EOF
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664 /var/log/lastlog
chmod -v 600 /var/log/btmp

log "7.7 gettext (temp)"
enter gettext-1.0 gettext-1.0.tar.xz
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
leave gettext-1.0

log "7.8 bison (temp)"
enter bison-3.8.2 bison-3.8.2.tar.xz
./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
make
make install
leave bison-3.8.2

log "7.9 perl (temp)"
enter perl-5.44.0 perl-5.44.0.tar.xz
sh Configure -des -D prefix=/usr -D vendorprefix=/usr -D useshrplib \
	-D privlib=/usr/lib/perl5/5.44/core_perl \
	-D archlib=/usr/lib/perl5/5.44/core_perl \
	-D sitelib=/usr/lib/perl5/5.44/site_perl \
	-D sitearch=/usr/lib/perl5/5.44/site_perl \
	-D vendorlib=/usr/lib/perl5/5.44/vendor_perl \
	-D vendorarch=/usr/lib/perl5/5.44/vendor_perl
make
make install
leave perl-5.44.0

log "7.10 zlib (temp)"
enter zlib-1.3.2 zlib-1.3.2.tar.gz
./configure --prefix=/usr
make
make install
rm -fv /usr/lib/libz.a
leave zlib-1.3.2

log "7.11 mpdecimal (temp)"
enter mpdecimal-4.0.1 mpdecimal-4.0.1.tar.gz
./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/mpdecimal-4.0.1
make
make install
leave mpdecimal-4.0.1

log "7.12 python (temp)"
enter Python-3.14.7 Python-3.14.7.tar.xz
./configure --prefix=/usr --enable-shared --without-ensurepip --without-static-libpython
make
make install
leave Python-3.14.7

log "7.13 texinfo (temp)"
enter texinfo-7.3 texinfo-7.3.tar.xz
./configure --prefix=/usr
make
make install
leave texinfo-7.3

log "7.14 util-linux (temp)"
mkdir -pv /var/lib/hwclock
enter util-linux-2.42.2 util-linux-2.42.2.tar.xz
./configure --libdir=/usr/lib   \
            --runstatedir=/run  \
            --disable-chfn-chsh \
            --disable-login     \
            --disable-nologin   \
            --disable-su        \
            --disable-setpriv   \
            --disable-runuser   \
            --disable-pylibmount \
            --disable-static    \
            --disable-liblastlog2 \
            --without-python    \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-2.42.2
make
make install
leave util-linux-2.42.2

log "scaffold: ninja (temp; meson-based recipes drive it)"
enter ninja-1.13.2 ninja-1.13.2.tar.gz
python3 configure.py --bootstrap --verbose
install -vm755 ninja /usr/bin/
leave ninja-1.13.2

log "scaffold: go bootstrap toolchain (for the go recipe's source build)"
sha256sum -c <<'GOSUM'
7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840  /sources/go1.27.4.linux-amd64.tar.gz
GOSUM
tar -xf /sources/go1.27.4.linux-amd64.tar.gz -C /opt
rm -rf /opt/go-bootstrap
mv /opt/go /opt/go-bootstrap

log "7.15 cleaning up the temporary system"
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name '*.la' -delete
rm -rf /tools

printf '\n== stage1 complete\n'
