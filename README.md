# servers-config

Ryzen主系サーバーと、将来移行するROCK 3B待機系のNixOS構成。

- [要件・ロードマップ](requirements-and-roadmap.md)
- [Ryzen SSD・RAID復旧手順](docs/ryzen-storage-recovery.md)
- [Nix Remote Builderの適用・運用手順](docs/nix-remote-builder.md)
- [Nix Binary Cache・12時間ごとの更新計画](docs/nix-binary-cache.md)
- [Forgejoの移行・公開手順](docs/forgejo-migration.md)
- [Actions Runnerの登録・Web CI確認手順](docs/forgejo-runner.md)
- [Ryzen Webデプロイ・公開切替手順](docs/web-deployment.md)

Phase 4のForgejo移行は2026-09-29に実用上完了。ROCK本体停止試験は未実施、
ROCK側の設定整理は保留。
Phase 5はRyzen RunnerでWebビルドとCI失敗時の本番維持を確認済み。
Phase 6は2026-09-29に完了。DNS切替後の公開アクセス、実機でのビルド失敗時の
release維持、復旧後の正常デプロイと公開`/healthz`を確認済み。

```text
flake.nix
hosts/ryzen/           ホスト設定・ディスク・ハードウェア
modules/system/       SSH・Mesh・保守・管理ユーザー
tests/forgejo.nix       Forgejo移行・起動抑止・Mesh SSH制限の試験
tests/web.nix           nginx・healthz・公開release切替の試験
```

`nixpkgs`は既存の`~/nixos-config`と同じrevisionから開始し、`flake.lock`で固定。
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

`nix flake check`は使い捨てVMでForgejoの移行前の起動抑止、データ・鍵の引き継ぎ、
新しいclone URL、定期dump、Mesh経由だけのGit SSH接続を確認する。
x86_64 LinuxとKVMが必要。実機のディスクにはアクセスしない。
新しいファイルを追加した場合は、flakeから参照できるようGitに追加する。
ビルド・検証コマンドは現在のホストへ設定を適用しない。
