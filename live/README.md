# ZIGNOS Live ISO build

デスクトップ Live ISO を組み立てるスクリプト一式。実行中の ZIGNOS デスクトップを
`/var/tmp/desktop-live/root` にステージし、squashfs・initramfs・BIOS/UEFI の
El Torito イメージ・ハイブリッド ISO を作る。すべて root で実行する。

## ファイル

| ファイル | 内容 |
|---|---|
| `stage-desktop.sh` | 実行中のデスクトップを `/var/tmp/desktop-live/root` にコピー |
| `sanitize-desktop.sh` | ステージした root からホスト固有の情報を除去(冪等) |
| `build-desktop-iso.sh` | initramfs・squashfs(gzip)・EFI イメージ・ISO ツリーを `/var/tmp/desktop-live/iso` に作成 |
| `make-iso.py` | ISO9660 + BIOS/UEFI El Torito の ISO を pycdlib で作成 |
| `build-root.sh` | 旧来のオールインワン build スクリプト(参考) |
| `init` | initramfs の `/init`。`LABEL="ZIGNOSLIVE"` を探して squashfs を overlay でマウント |
| `grub.cfg` | BIOS / UEFI 共通の GRUB メニュー |
| `zignos-install` / `zignos-installer` | Live root に導入するインストーラー。リポジトリ直下の `zignos-install.sh` / `zignos-installer.sh` と同期する |
| `zignos-installer.desktop` | Live セッションの「Install ZIGNOS」ランチャー |

## 前提

- ZIGNOS の testing デスクトップ(Plasma / GRUB / zpkg が入っていること)
- `grub-mkimage` / `grub-mkstandalone`、`mkfs.vfat`、`mount`、`mksquashfs`
- `pycdlib`(ISO 作成)、`xorriso`(ハイブリッド ISO)
- `/var/tmp/desktop-live/root`(ステージ先)と `/var/tmp/desktop-live/iso`(出力)

`build-desktop-iso.sh` の `KVER` と `MKSQUASHFS` は環境に合わせて変更する。

## ビルド

```sh
# 1. 実行中のデスクトップをステージ
sudo ./stage-desktop.sh
# 2. ホスト固有の情報を除去
sudo ./sanitize-desktop.sh
# 3. squashfs / initramfs / EFI / ISO ツリー
sudo ./build-desktop-iso.sh
# 4. ISO9660 + El Torito
TREE=/var/tmp/desktop-live/iso python3 make-iso.py /var/tmp/zignos-live.iso
```

### 環境変数

| 変数 | 既定 | 内容 |
|---|---|---|
| `SOURCE_USER` | `zignos` | Live root から削除するホストのユーザー名。ビルドホストのアカウントを指定する |
| `LIVE_SANITIZE_PATTERNS` | 空 | `/etc` などを走査する追加パターン(ユーザー名・ホスト名・IP 前置・秘密情報)。**ローカルの値はコミットしない** |
| `TREE` | `/var/tmp/live-iso` | `make-iso.py` が読む ISO ツリー |
| `BUILD` | スクリプトのディレクトリ | `build-desktop-iso.sh` / `build-root.sh` が使う |

例:

```sh
sudo SOURCE_USER=youruser \
  LIVE_SANITIZE_PATTERNS="youruser yourhost 10.0.0. your-secret" \
  ./stage-desktop.sh
```

## ハイブリッド ISO(USB 起動)

`make-iso.py` が作る ISO は **CD/DVD 用**(ISO9660 + El Torito)で、MBR/GPT を
持たないため USB に `dd` しても起動しない。USB 起動には xorriso で MBR と
GPT/ESP を追加する:

```sh
xorriso -as mkisofs -o /var/tmp/zignos-live-hybrid.iso \
  -volid ZIGNOSLIVE -iso-level 3 -J -joliet-long \
  -b boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 \
  -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -eltorito-platform efi -e efi.img -no-emul-boot \
  -isohybrid-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -isohybrid-gpt-basdat \
  /var/tmp/desktop-live/iso
```

- **`-isohybrid-gpt-basdat` は `-isohybrid-mbr` と組み合わせないと GPT が作られない**
  (`--grub2-mbr` では GPT が付かない)
- ボリュームラベルは `ZIGNOSLIVE` にする。initramfs の `init` が
  `blkid` の `LABEL="ZIGNOSLIVE"` で起動メディアを探すため
- USB は 8 GB 以上を推奨(ISO は約 4.4 GB)

## 検証

`-cdrom` だけでは El Torito 経由の確認にしかならず、USB 起動の欠陥を見逃す。
QEMU では **USB ストレージとして**接続し、BIOS(SeaBIOS)と UEFI(OVMF)の
両方で GRUB から起動することを確認する:

```sh
qemu-system-x86_64 -machine q35,accel=tcg,hpet=off -m 3072 -smp 4 \
  -device qemu-xhci,id=xhci \
  -drive if=none,id=usb,file=zignos-live-hybrid.iso,format=raw,readonly=on \
  -device usb-storage,drive=usb,bus=xhci.0 \
  -serial tcp:127.0.0.1:5555,server=on,wait=on -display none
```

UEFI は `-drive if=pflash,format=raw,readonly=on,file=edk2-x86_64-code.fd` を足す。
起動後、シリアルに `ZIGNOS Live: medium /dev/sda` が出ればメディアを認識している。
