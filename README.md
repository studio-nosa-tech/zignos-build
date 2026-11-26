# zignos-build

ZIGNOS の bootstrap・イメージ/ stage3 作成・起動テストのスクリプト群。
レシピツリーは `stable` / `testing` / `unstable` の3チャンネルを持ち、
ビルドスクリプトは `CHANNEL`(既定 `stable`)で使用チャンネルを選ぶ。

## スクリプト

| ファイル | 内容 | 実行環境 |
|---|---|---|
| `bootstrap.sh` | オーケストレータ(ソース取得 → lfs ユーザ → chroot → stage 実行) | build VM 上で root |
| `stage0.sh` | LFS ch4/ch5/ch6: cross toolchain + 一時ツール | lfs ユーザ(bootstrap.sh が呼ぶ) |
| `stage1.sh` | LFS ch7: chroot 準備・essential files・追加一時ツール + Go bootstrap スキャフォールド | chroot 内(bootstrap.sh が呼ぶ) |
| `stage2.sh` | zpkg による最終システム構築(glibc → gcc → … → zpkg 自家ホスト)。`CHANNEL` のレシピを使い、bootstrap 中は `ZPKG_SANDBOX=off` | chroot 内(bootstrap.sh が呼ぶ) |
| `base.list` | ベースシステムの唯一の定義(**トップレベル 38 個**。依存込みで 67) | - |
| `build-system.sh` | base.list をルートへ冪等適用(ローリング更新の主力)。`CHANNEL` 対応 | ホスト or chroot |
| `make-image.sh` | 起動可能イメージ(BIOS/MBR、`UEFI=1` で GPT+ESP)。選択チャンネルだけ同梱 | build VM 上で root |
| `make-seed.sh` | 実行中システムのフル seed tarball(開発者向け) | root |
| `make-stage3.sh` | **stage3 tarball**(base.list の依存クロージャ − linux/grub = 67 パッケージ)。選択チャンネルだけ同梱し、`/etc/zpkg/make.conf` に CHANNEL を書く。`/etc/zpkg/sync.conf` は既定の GitHub レシピリポジトリを指す | root |
| `zignos-install.sh` | 実行中システムを別ディスクへインストール(BIOS/UEFI 自動判定または `ZIGNOS_FIRMWARE` 指定、Live ISO からは live 専用設定を除去、efibootmgr があれば NVRAM 登録) | 実行中 ZIGNOS 内で root |
| `zignos-installer.sh` | whiptail による TUI フロントエンド。ディスク・ファームウェア・ホスト名・ユーザー・ロケール・キーマップ・タイムゾーンを対話設定して `zignos-install --yes` を実行(`--auto` は環境変数で非対話)。インストール中は **進捗ゲージ**(コピー済み容量/推定総量のバーとパーセント)を表示。Live ISO の `/usr/sbin/zignos-installer` とアプリメニュー「Install ZIGNOS」 | Live ISO 内で root |
| `live/` | デスクトップ Live ISO のビルド一式。stage/sanitize → squashfs/initramfs → BIOS/UEFI El Torito → ハイブリッド(USB)ISO。詳細は `live/README.md` | build VM 上で root |
| `zignos-enter.sh` | private mount namespace で展開先に vfs をマウントして chroot(seed/stage3 用)。bwrap の pivot_root が動く | root |
| `qemu-test.sh` | QEMU 起動チェック(`check`。`UEFI=1` で OVMF)。結果を manifest 用 JSON に記録 | build VM 上 |
| `release.conf` | リリース名・stage3 revision・availability の既定値 | - |
| `release-manifest.py` | `release.json` の生成(`generate`)・起動結果の記録(`record-boot`)・検証(`validate`) | python3 |
| `publish-release.sh` | manifest を検証し、`zignos/releases/` とサイトへ配置 | python3 |

参照手順: LFS 13.1-systemd(`stage0/1.sh` は書籍に忠実、`stage2.sh` は zpkg レシピに翻訳)。意図的な差分は `bootstrap.sh` のヘッダーコメントを参照。

## 使い方(build VM 内・root)

1. ルートを `$ZIGNOS_ROOT`(既定 `/mnt`)にマウント(VM では `/var/zignos.img` を loop)
2. 4 リポジトリを `~/zignos` 下に clone、Go を導入(zignos/docs/env.md)
3. `sudo ./bootstrap.sh`(チャンネルを変えるなら `sudo CHANNEL=testing ./bootstrap.sh`)

`CHANNEL` は `stable`(既定)/ `testing` / `unstable`。レシピの変更は
`unstable → testing → stable` の順に昇格させる。stage3 / イメージには選択した
チャンネルだけが入り、他のチャンネルは後から `zpkg sync` で追加する。

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

`base.list` は **Gentoo @system 相当のトップレベルだけ**(38 個)。依存と
makedepends は zpkg が解決するので、実際のベースは閉包 67 パッケージになる。
SSH / DHCP / エディタ / man / doas などは `zpkg install` で後から入れる。

## イメージと stage3

```bash
# BIOS イメージ(MBR + ext4)
sudo OUT=/var/tmp/zignos-bios.img ./make-image.sh

# UEFI イメージ(GPT + 100MiB ESP)。ホストに mkfs.vfat / losetup が必要
sudo UEFI=1 OUT=/var/tmp/zignos-uefi.img ./make-image.sh

# stage3(カーネル抜きの chroot ベース、約 1GB)
sudo OUT=/var/tmp/zignos-stage3-20261119-r12-x86_64.tar.xz ./make-stage3.sh

# チャンネルを指定(既定 stable)
sudo CHANNEL=testing OUT=/var/tmp/zignos-stage3-testing.tar.xz ./make-stage3.sh
```

stage3 は base.list の**依存クロージャ**から linux/grub(と linux 専用の
bison/bc/elfutils/kmod/initramfs)を除いた 54 パッケージ。展開後は
`zignos-enter.sh <target>` で chroot し、`zpkg install linux grub` で仕上げる。ビルド時には `<OUT>.release.json`
(リリースマニフェスト)と、全チャンネルのレシピ tarball・zpkg バイナリも生成する。
同梱されるレシピは `/usr/share/zignos/recipes/<channel>/` の1チャンネルだけで、
`/etc/zpkg/make.conf` の `CHANNEL=` がそのチャンネルを指す。
`/etc/zpkg/sync.conf` は `zpkg sync` の既定取得元で、GitHub の
`studio-nosa-tech/zignos-recipes` を git モードで参照する。

## デスクトップ Live ISO

`live/` に、実行中の testing デスクトップから Live ISO を作るスクリプト一式がある
(`stage-desktop.sh` → `sanitize-desktop.sh` → `build-desktop-iso.sh` →
`make-iso.py`)。USB 起動には MBR/GPT/ESP を付けたハイブリッド ISO が必要で、
xorriso の `-isohybrid-mbr` + `-isohybrid-gpt-basdat` で作成する(手順・環境変数・
QEMU での USB 検証は `live/README.md`)。同梱の `zignos-install` /
`zignos-installer` はリポジトリ直下の `zignos-install.sh` /
`zignos-installer.sh` と同期させる。

## qemu-test.sh

```bash
IMG=/var/tmp/zignos-bios.img ./qemu-test.sh check          # BIOS
UEFI=1 IMG=/var/tmp/zignos-uefi.img ./qemu-test.sh check   # UEFI (OVMF)
```

シリアルに root / zignos でログインし、`ZIGNOS-BOOT-OK <kernel>` と `OpenRC` が
出れば `BOOT CHECK PASSED`。結果は `release-manifest.py record-boot` で
`/var/tmp/zignos-boot-tests.json` に記録され、次の manifest 生成で取り込まれる。TCG では稀に `IO-APIC + timer doesn't work!` で
止まることがあるので、失敗時は同じイメージで再試行する。

## リリースビルド

リリース名と stage3 revision は `release.conf` で決める(環境変数で上書き可能)。

```bash
# 1. stage3 と配布物・manifest を生成
sudo ZIGNOS_ROOT=/mnt OUT=/var/tmp/zignos-stage3-20261119-r12-x86_64.tar.xz \
  ./make-stage3.sh

# 2. manifest を検証して zignos/releases とサイトへ配置
./publish-release.sh /var/tmp/zignos-stage3-20261119-r12-x86_64.tar.xz.release.json

# 3. サイトをビルド
cd ~/ZIGNOS-Official && npm run build
```

`make-stage3.sh` は stage3 の DB からパッケージ一覧を読み、`zpkg` / `linux` /
`grub` の版、base closure、レシピ数、ソースコミット、起動結果、配布物の
SHA-256 を `release.json` にまとめる。ステージ3の SHA-256 は tarball に
埋め込めないため、manifest は sidecar(`<OUT>.release.json`)になる。

起動検証を manifest に反映する場合:

```bash
IMG=/var/tmp/zignos-bios.img ./qemu-test.sh check
sudo OUT=/var/tmp/zignos-stage3-20261119-r12-x86_64.tar.xz ./make-stage3.sh
```

`qemu-test.sh` は `/var/tmp/zignos-boot-tests.json` に BIOS / UEFI の結果を
書く。結果ファイルが無い場合、manifest の `boot` は全項目 `not-tested` になる。
