# zignos-build

ZIGNOS の bootstrap・イメージ/ stage3 作成・起動テストのスクリプト群。

## スクリプト

| ファイル | 内容 | 実行環境 |
|---|---|---|
| `bootstrap.sh` | オーケストレータ(ソース取得 → lfs ユーザ → chroot → stage 実行) | build VM 上で root |
| `stage0.sh` | LFS ch4/ch5/ch6: cross toolchain + 一時ツール | lfs ユーザ(bootstrap.sh が呼ぶ) |
| `stage1.sh` | LFS ch7: chroot 準備・essential files・追加一時ツール + Go bootstrap スキャフォールド | chroot 内(bootstrap.sh が呼ぶ) |
| `stage2.sh` | zpkg による最終システム構築(glibc → gcc → … → zpkg 自家ホスト)。bootstrap 中は `ZPKG_SANDBOX=off` | chroot 内(bootstrap.sh が呼ぶ) |
| `base.list` | ベースシステムの唯一の定義(**トップレベル 37 個**。依存込みで 60) | - |
| `build-system.sh` | base.list をルートへ冪等適用(ローリング更新の主力) | ホスト or chroot |
| `make-image.sh` | 起動可能イメージ(BIOS/MBR、`UEFI=1` で GPT+ESP) | build VM 上で root |
| `make-seed.sh` | 実行中システムのフル seed tarball(開発者向け) | root |
| `make-stage3.sh` | **stage3 tarball**(base.list の依存クロージャ − linux/grub = 54 パッケージ)。chroot して `zpkg install linux grub` で完成 | root |
| `zignos-install.sh` | 実行中システムを別ディスクへインストール(BIOS/UEFI 自動判定、efibootmgr があれば NVRAM 登録) | 実行中 ZIGNOS 内で root |
| `zignos-enter.sh` | private mount namespace で展開先に vfs をマウントして chroot(seed/stage3 用)。bwrap の pivot_root が動く | root |
| `qemu-test.sh` | QEMU 起動チェック(`check`。`UEFI=1` で OVMF) | build VM 上 |

参照手順: LFS 13.1-systemd(`stage0/1.sh` は書籍に忠実、`stage2.sh` は zpkg レシピに翻訳)。意図的な差分は `bootstrap.sh` のヘッダーコメントを参照。

## 使い方(build VM 内・root)

1. ルートを `$ZIGNOS_ROOT`(既定 `/mnt`)にマウント(VM では `/var/zignos.img` を loop)
2. 4 リポジトリを `~/zignos` 下に clone、Go を導入(zignos/docs/env.md)
3. `sudo ./bootstrap.sh`

- ソース一式は `$ZIGNOS_ROOT/sources` に自動ダウンロードされ、sha256 検証される。
  時計ずれ等で取得できない場合は `curl -k` したファイルを
  `$ZIGNOS_ROOT/var/cache/zpkg/<URL の basename>` に置くとキャッシュされる
- stage2 で失敗した場合は bootstrap.sh を実行し直すと、zpkg がインストール済み
  パッケージをスキップするため stage2 から再開しやすい(stage0/1 は未対応)
- stage0(ツールチェーン)に 1〜2 時間、stage2(最終システム)に 2〜4 時間程度

## ベースシステムの適用・検証

```bash
# レシピツリーを最新にして base.list を適用(冪等)
cd ~/zignos/zignos-recipes && git pull
cd ~/zignos/zignos-build && sudo ./build-system.sh /mnt

# 何が入るかの確認(pretend)
sudo ./build-system.sh /mnt -p
```

`base.list` は **Gentoo @system 相当のトップレベルだけ**(36 個)。依存と
makedepends は zpkg が解決するので、実際のベースは閉包 59 パッケージになる。
SSH / DHCP / エディタ / man / doas などは `zpkg install` で後から入れる。

## イメージと stage3

```bash
# BIOS イメージ(MBR + ext4)
sudo OUT=/var/tmp/zignos-bios.img ./make-image.sh

# UEFI イメージ(GPT + 100MiB ESP)。ホストに mkfs.vfat / losetup が必要
sudo UEFI=1 OUT=/var/tmp/zignos-uefi.img ./make-image.sh

# stage3(カーネル抜きの chroot ベース、約 1GB)
sudo OUT=/var/tmp/zignos-stage3.tar.xz ./make-stage3.sh
```

stage3 は base.list の**依存クロージャ**から linux/grub(と linux 専用の
bison/bc/elfutils/kmod/initramfs)を除いた 53 パッケージ。展開後は
`zignos-enter.sh <target>` で chroot し、`zpkg install linux grub` で仕上げる。

## qemu-test.sh

```bash
IMG=/var/tmp/zignos-bios.img ./qemu-test.sh check          # BIOS
UEFI=1 IMG=/var/tmp/zignos-uefi.img ./qemu-test.sh check   # UEFI (OVMF)
```

シリアルに root / zignos でログインし、`ZIGNOS-BOOT-OK <kernel>` と `OpenRC` が
出れば `BOOT CHECK PASSED`。TCG では稀に `IO-APIC + timer doesn't work!` で
止まることがあるので、失敗時は同じイメージで再試行する。
