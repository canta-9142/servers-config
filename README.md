# servers-config

Ryzen主系サーバーと、将来移行するROCK 3B待機系のNixOS構成。
現在の実装対象はPhase 1（Ryzen基盤）のみ。

- [要件・ロードマップ](requirements-and-roadmap.md)
- [Ryzen初回インストール・受入確認](docs/phase-1-install.md)

```text
flake.nix
hosts/ryzen/           ホスト設定・ディスク・ハードウェア
modules/system/       SSH・Mesh・保守・管理ユーザー
tests/raid-boot.nix     UEFI・縮退起動・メンバー再参加と再同期の試験
```

`nixpkgs`は既存の`~/nixos-config`と同じrevisionから開始し、`flake.lock`で固定。
ハードウェア設定は実機で生成し直す。それまでは一般的なRyzen/NVMe構成を使用する。
ROCK 3Bの既存環境は変更しない。

## 開発・検証

```sh
nix develop
nix fmt
statix check .
deadnix --fail .
nix flake check
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
```

`nix flake check`は使い捨ての仮想ディスクへインストールして起動を検証する。
mdadm RAID1 + ext4を作成し、両方向の縮退起動、縮退中の書き込み、古いメンバーの再参加、
再同期・再起動後のデータ保持、月次checkの実行を確認する。
x86_64 LinuxとKVMが必要。実機のディスクにはアクセスしない。
新しいファイルを追加した場合は、flakeから参照できるようGitに追加する。
ビルド・検証コマンドは現在のホストへ設定を適用しない。
