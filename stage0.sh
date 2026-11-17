#!/bin/bash
# ZIGNOS bootstrap stage0 — runs entirely as the lfs user.
# LFS 13.1-systemd ch5 (cross toolchain) + ch6 (cross-compiled temporary
# tools), installed into $ZIGNOS_ROOT. Faithful to the book; tests are not run.
#
# shellcheck disable=SC2086,SC2046,SC2016
# Book-transcribed LFS commands: unquoted $ZIGNOS_ROOT/$LFS_TGT are the book's own
# style, values are controlled (no spaces), and some seds intentionally use
# single quotes around literal $ patterns.
#
# Requires from the environment: ZIGNOS_ROOT, LFS_TGT, MAKEFLAGS
# (bootstrap.sh passes them; see also ch4.4 of the book).

set -euo pipefail
set +h
umask 022
LC_ALL=POSIX
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$ZIGNOS_ROOT/tools/bin:$PATH
CONFIG_SITE=$ZIGNOS_ROOT/usr/share/config.site
export ZIGNOS_ROOT LFS_TGT LC_ALL PATH CONFIG_SITE MAKEFLAGS

cd "$ZIGNOS_ROOT/sources"

log() { printf '\n== %s\n' "$*"; }

# enter <dir> <archive> — extract (if needed) and cd in
enter() {
	rm -rf "$1"
	tar -xf "$ZIGNOS_ROOT/sources/$2"
	cd "$1"
}

# leave <dir> — back to sources and clean up
leave() {
	cd "$ZIGNOS_ROOT/sources"
	rm -rf "$1"
}

build_binutils_pass1() {
	log "5.2 binutils pass1"
	enter binutils-2.47 binutils-2.47.tar.xz
	mkdir -v build && cd build
	../configure --prefix=$ZIGNOS_ROOT/tools          \
	             --with-sysroot=$ZIGNOS_ROOT          \
	             --target=$LFS_TGT            \
	             --disable-nls                \
	             --enable-gprofng=no          \
	             --disable-werror             \
	             --enable-new-dtags           \
	             --enable-default-hash-style=gnu
	make
	make install
	leave binutils-2.47
}

build_gcc_pass1() {
	log "5.3 gcc pass1"
	enter gcc-16.2.0 gcc-16.2.0.tar.xz
	tar -xf "$ZIGNOS_ROOT/sources/mpfr-4.2.2.tar.xz" && mv -v mpfr-4.2.2 mpfr
	tar -xf "$ZIGNOS_ROOT/sources/gmp-6.3.0.tar.xz" && mv -v gmp-6.3.0 gmp
	tar -xf "$ZIGNOS_ROOT/sources/mpc-1.4.1.tar.xz" && mv -v mpc-1.4.1 mpc
	case $(uname -m) in
		x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
	esac
	mkdir -v build && cd build
	../configure                                 \
	    --target=$LFS_TGT                        \
	    --prefix=$ZIGNOS_ROOT/tools                      \
	    --with-glibc-version=2.44                \
	    --with-sysroot=$ZIGNOS_ROOT                      \
	    --with-newlib                            \
	    --without-headers                        \
	    --enable-default-pie                     \
	    --enable-default-ssp                     \
	    --disable-fixincludes                    \
	    --disable-nls                            \
	    --disable-shared                         \
	    --disable-multilib                       \
	    --disable-threads                        \
	    --disable-libatomic                      \
	    --disable-libgomp                        \
	    --disable-libquadmath                    \
	    --disable-libssp                         \
	    --disable-libvtv                         \
	    --disable-libstdcxx                      \
	    --enable-languages=c,c++
	make
	make install
	cat ../gcc/{limitx,glimits,limity}.h > "$($LFS_TGT-gcc -print-file-name=include)/limits.h"
	leave gcc-16.2.0
}

build_linux_headers() {
	log "5.4 linux api headers"
	enter linux-7.1.8 linux-7.1.8.tar.xz
	make mrproper
	make headers
	find usr/include -type f ! -name '*.h' -delete
	cp -rv usr/include "$ZIGNOS_ROOT/usr"
	leave linux-7.1.8
}

build_glibc_cross() {
	log "5.5 glibc (cross)"
	enter glibc-2.44 glibc-2.44.tar.xz
	patch -Np1 -i "$ZIGNOS_ROOT/sources/glibc-fhs-1.patch"
	patch -Np1 -i "$ZIGNOS_ROOT/sources/glibc-2.44-upstream_fixes-1.patch"
	case $(uname -m) in
		i?86) ln -sfv ld-linux.so.2 "$ZIGNOS_ROOT/lib/ld-lsb.so.3" ;;
		x86_64)
			ln -sfv ../lib/ld-linux-x86-64.so.2 "$ZIGNOS_ROOT/lib64"
			ln -sfv ../lib/ld-linux-x86-64.so.2 "$ZIGNOS_ROOT/lib64/ld-lsb-x86-64.so.3"
			;;
	esac
	mkdir -v build && cd build
	echo "rootsbindir=/usr/sbin" > configparms
	../configure                             \
	    --prefix=/usr                        \
	    --host=$LFS_TGT                      \
	    --build=$(../scripts/config.guess)   \
	    --disable-nscd                       \
	    libc_cv_slibdir=/usr/lib             \
	    --enable-kernel=5.10
	make
	make DESTDIR=$ZIGNOS_ROOT install
	sed '/RTLDLIST=/s@/usr@@g' -i "$ZIGNOS_ROOT/usr/bin/ldd"
	leave glibc-2.44
}

build_libstdcxx() {
	log "5.6 libstdc++"
	enter gcc-16.2.0 gcc-16.2.0.tar.xz
	mkdir -v build && cd build
	../libstdc++-v3/configure                    \
	    --host=$LFS_TGT                          \
	    --build=$(../config.guess)               \
	    CXX=$LFS_TGT-gcc                         \
	    --prefix=/usr                            \
	    --disable-multilib                       \
	    --disable-nls                            \
	    --disable-libstdcxx-pch                  \
	    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/16.2.0
	make
	make DESTDIR=$ZIGNOS_ROOT install
	rm -v "$ZIGNOS_ROOT"/usr/lib/lib{stdc++{,exp,fs},supc++}.la
	leave gcc-16.2.0
}

build_config_site() {
	log "6.2 config.site"
	mkdir -pv "$ZIGNOS_ROOT/usr/share"
	cat > "$ZIGNOS_ROOT/usr/share/config.site" <<'CSITE'
ac_cv_func_posix_spawn_file_actions_addchdir=yes
ac_cv_func_posix_spawn_file_actions_addfchdir=yes
CSITE
}

build_m4() {
	log "6.2 m4"
	enter m4-1.4.21 m4-1.4.21.tar.xz
	./configure --prefix=/usr   \
	            --host=$LFS_TGT \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave m4-1.4.21
}

build_ncurses() {
	log "6.3 ncurses"
	enter ncurses-6.6 ncurses-6.6.tar.gz
	mkdir build
	pushd build
	../configure --prefix=$ZIGNOS_ROOT/tools AWK=gawk
	make -C include
	make -C progs tic
	install -vm755 progs/tic "$ZIGNOS_ROOT/tools/bin"
	popd
	./configure --prefix=/usr    \
	            --host=$LFS_TGT  \
	            --build=$(./config.guess) \
	            --mandir=/usr/share/man \
	            --with-manpage-format=normal \
	            --with-shared    \
	            --without-normal \
	            --with-cxx-shared \
	            --without-debug  \
	            --without-ada    \
	            --disable-stripping \
	            AWK=gawk
	make
	make DESTDIR=$ZIGNOS_ROOT install
	ln -sv libncursesw.so "$ZIGNOS_ROOT/usr/lib/libncurses.so"
	sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$ZIGNOS_ROOT/usr/include/curses.h"
	leave ncurses-6.6
}

build_bash() {
	log "6.4 bash"
	enter bash-5.3 bash-5.3.tar.gz
	./configure --prefix=/usr                      \
	            --build=$(sh support/config.guess) \
	            --host=$LFS_TGT                    \
	            --without-bash-malloc              \
	            --docdir=/usr/share/doc/bash-5.3
	make
	make DESTDIR=$ZIGNOS_ROOT install
	ln -sv bash "$ZIGNOS_ROOT/bin/sh"
	leave bash-5.3
}

build_coreutils() {
	log "6.5 coreutils"
	enter coreutils-9.11 coreutils-9.11.tar.xz
	./configure --prefix=/usr            \
	            --host=$LFS_TGT          \
	            --build=$(build-aux/config.guess) \
	            --enable-install-program=hostname
	make
	make DESTDIR=$ZIGNOS_ROOT install
	mv -v "$ZIGNOS_ROOT/usr/bin/chroot" "$ZIGNOS_ROOT/usr/sbin"
	mkdir -pv "$ZIGNOS_ROOT/usr/share/man/man8"
	mv -v "$ZIGNOS_ROOT/usr/share/man/man1/chroot.1" "$ZIGNOS_ROOT/usr/share/man/man8/chroot.8"
	sed -i 's/"1"/"8"/' "$ZIGNOS_ROOT/usr/share/man/man8/chroot.8"
	leave coreutils-9.11
}

build_diffutils() {
	log "6.6 diffutils"
	enter diffutils-3.12 diffutils-3.12.tar.xz
	./configure --prefix=/usr  \
	            --host=$LFS_TGT \
	            gl_cv_func_strcasecmp_works=yes \
	            --build=$(./build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave diffutils-3.12
}

build_file() {
	log "6.7 file"
	enter file-5.48 file-5.48.tar.gz
	mkdir build
	pushd build
	../configure --disable-bzlib      \
	             --disable-libseccomp \
	             --disable-xzlib      \
	             --disable-zlib
	make
	popd
	./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)
	make FILE_COMPILE=$(pwd)/build/src/file
	make DESTDIR=$ZIGNOS_ROOT install
	rm -v "$ZIGNOS_ROOT/usr/lib/libmagic.la"
	leave file-5.48
}

build_findutils() {
	log "6.8 findutils"
	enter findutils-4.11.0 findutils-4.11.0.tar.xz
	./configure --prefix=/usr       \
	            --localstatedir=/var/lib/locate \
	            --host=$LFS_TGT     \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave findutils-4.11.0
}

build_gawk() {
	log "6.9 gawk"
	enter gawk-5.4.1 gawk-5.4.1.tar.xz
	sed -i 's/extras//' Makefile.in
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave gawk-5.4.1
}

build_grep() {
	log "6.10 grep"
	enter grep-3.12 grep-3.12.tar.xz
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(./build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave grep-3.12
}

build_gzip() {
	log "6.11 gzip"
	enter gzip-1.14 gzip-1.14.tar.xz
	# Note: no --build on purpose (the book builds gzip this way).
	./configure --prefix=/usr --host=$LFS_TGT
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave gzip-1.14
}

build_make() {
	log "6.12 make"
	enter make-4.4.1 make-4.4.1.tar.gz
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave make-4.4.1
}

build_patch() {
	log "6.13 patch"
	enter patch-2.8 patch-2.8.tar.xz
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave patch-2.8
}

build_sed() {
	log "6.14 sed"
	enter sed-4.10 sed-4.10.tar.xz
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(./build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave sed-4.10
}

build_tar() {
	log "6.15 tar"
	enter tar-1.35 tar-1.35.tar.xz
	./configure --prefix=/usr \
	            --host=$LFS_TGT \
	            --build=$(build-aux/config.guess)
	make
	make DESTDIR=$ZIGNOS_ROOT install
	leave tar-1.35
}

build_xz() {
	log "6.16 xz"
	enter xz-5.8.3 xz-5.8.3.tar.xz
	./configure --prefix=/usr       \
	            --host=$LFS_TGT     \
	            --build=$(build-aux/config.guess) \
	            --disable-static    \
	            --docdir=/usr/share/doc/xz-5.8.3
	make
	make DESTDIR=$ZIGNOS_ROOT install
	rm -v "$ZIGNOS_ROOT/usr/lib/liblzma.la"
	leave xz-5.8.3
}

build_binutils_pass2() {
	log "6.17 binutils pass2"
	enter binutils-2.47 binutils-2.47.tar.xz
	sed '6031s/$add_dir//' -i ltmain.sh
	mkdir -v build && cd build
	../configure                   \
	    --prefix=/usr              \
	    --build=$(../config.guess) \
	    --host=$LFS_TGT            \
	    --disable-nls              \
	    --enable-shared            \
	    --enable-gprofng=no        \
	    --disable-werror           \
	    --enable-64-bit-bfd        \
	    --enable-new-dtags         \
	    --enable-default-hash-style=gnu
	make
	make DESTDIR=$ZIGNOS_ROOT install
	rm -v "$ZIGNOS_ROOT"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
	leave binutils-2.47
}

build_gcc_pass2() {
	log "6.18 gcc pass2"
	enter gcc-16.2.0 gcc-16.2.0.tar.xz
	tar -xf "$ZIGNOS_ROOT/sources/mpfr-4.2.2.tar.xz" && mv -v mpfr-4.2.2 mpfr
	tar -xf "$ZIGNOS_ROOT/sources/gmp-6.3.0.tar.xz" && mv -v gmp-6.3.0 gmp
	tar -xf "$ZIGNOS_ROOT/sources/mpc-1.4.1.tar.xz" && mv -v mpc-1.4.1 mpc
	case $(uname -m) in
		x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
	esac
	unset CFLAGS CXXFLAGS LDFLAGS
	mkdir -v build && cd build
	../configure                                       \
	    --build=$(../config.guess)                     \
	    --host=$LFS_TGT                                \
	    --target=$LFS_TGT                              \
	    --prefix=/usr                                  \
	    --with-build-sysroot=$ZIGNOS_ROOT                      \
	    --enable-default-pie                           \
	    --enable-default-ssp                           \
	    --disable-fixincludes                          \
	    --disable-nls                                  \
	    --disable-multilib                             \
	    --disable-libatomic                            \
	    --disable-libgomp                              \
	    --disable-libquadmath                          \
	    --disable-libsanitizer                         \
	    --disable-libssp                               \
	    --disable-libvtv                               \
	    --enable-languages=c,c++                       \
	    CXX_FOR_TARGET="$LFS_TGT-gcc -nostdinc++"      \
	    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc      \
	    target_configargs=gcc_cv_target_thread_file=posix
	make
	make DESTDIR=$ZIGNOS_ROOT install
	ln -sv gcc "$ZIGNOS_ROOT/usr/bin/cc"
	leave gcc-16.2.0
}

build_config_site
build_binutils_pass1
build_gcc_pass1
build_linux_headers
build_glibc_cross
build_libstdcxx
build_m4
build_ncurses
build_bash
build_coreutils
build_diffutils
build_file
build_findutils
build_gawk
build_grep
build_gzip
build_make
build_patch
build_sed
build_tar
build_xz
build_binutils_pass2
build_gcc_pass2

printf '\n== stage0 complete\n'
