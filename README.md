# zignos-build

ZIGNOS の bootstrap・イメージ作成・起動テストのスクリプト群。

## スクリプト

| ファイル | 内容 | 実行環境 |
|---|---|---|
| `bootstrap.sh` | オーケストレータ(ソース取得 → lfs ユーザ → chroot → stage 実行) | build VM 上で root |
| `stage0.sh` | LFS ch4/ch5/ch6: cross toolchain + 一時ツール | lfs ユーザ(bootstrap.sh が呼ぶ) |
| `stage1.sh` | LFS ch7: chroot 準備・essential files・追加一時ツール + Go bootstrap スキャフォールド | chroot 内(bootstrap.sh が呼ぶ) |
| `stage2.sh` | zpkg による最終システム構築(glibc → gcc → … → zpkg 自家ホスト) | chroot 内(bootstrap.sh が呼ぶ) |
| `base.list` | ベースシステムの唯一の定義(`build-system.sh` が適用) | - |
| `build-system.sh` | base.list をルートへ冪等適用(ローリング更新の主力) | ホスト or chroot |
| `make-image.sh` | 起動可能イメージ(BIOS/MBR、`UEFI=1` で GPT+ESP) | build VM 上で root |
| `make-seed.sh` | 実行中システムのフル seed tarball(開発者向け) | root |
| `make-stage3.sh` | **stage3 tarball**(base − linux/grub、chroot して zpkg で完成) | root |
| `zignos-install.sh` | 実行中システムを別ディスクへインストール(BIOS/UEFI 自動判定) | 実行中 ZIGNOS 内で root |
| `zignos-enter.sh` | 展開先に vfs をマウントして chroot(seed/stage3 用) | root |
| `qemu-test.sh` | QEMU 起動テスト(`check`、`UEFI=1` で OVMF) | build VM 上で root |

参照手順: LFS 13.1-systemd(`stage0/1.sh` は書籍に忠実、`stage2.sh` は zpkg レシピに翻訳)。意図的な差分は `bootstrap.sh` のヘッダーコメントを参照。

## 使い方(build VM 内・root)

1. clean なパーティションを `$LFS`(既定 `/mnt/lfs`)に ext4 でマウント
2. 4 リポジトリを `~/zignos` 下に clone、Go を導入(zignos/docs/env.md)
3. `sudo ./bootstrap.sh`

- ソース一式(約 480MB)は `$LFS/sources` に自動ダウンロードされ、md5/sha256 検証される
- stage2 で失敗した場合は bootstrap.sh を実行し直すと、zpkg がインストール済みパッケージをスキップするため stage2 から再開しやすい(stage0/1 は未対応 — その場合は手動で途中位置から)
- stage0(ツールチェーン)に 1〜2 時間、stage2(最終システム)に 2〜4 時間程度を見込む

## qemu-test.sh

M3 で実装(kernel + init + rootfs イメージ生成後)。
