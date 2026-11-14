# zignos-build

ZIGNOS の bootstrap・イメージ作成・起動テストのスクリプト群。

## スクリプト

| スクリプト | 内容 | 状態 |
|---|---|---|
| `bootstrap.sh` | 3 段階 bootstrap のオーケストレータ | 骨格(M2 で実装) |
| `qemu-test.sh` | QEMU での起動テスト | 骨格(M3 で実装) |

## bootstrap の段階

1. **stage0(host)**: ホストビルドの zpkg が cross toolchain(binutils pass1 / gcc pass1 / kernel headers / glibc)を構築
2. **stage1(temp chroot)**: ツールチェーンを native 再構築 → Go をソースビルド → zpkg を再構築(自家ホスト開始)
3. **stage2(native)**: chroot 内の zpkg が core レシピからベースシステムを組み立て

参照手順: LFS 13.1。方針の詳細は zignos リポジトリの `docs/design-pkg.md` / `docs/design-system.md`。

## 使い方(現状は骨格確認)

```sh
cd zignos-build
./bootstrap.sh        # TODO 表示のみ
```
