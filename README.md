# servers-config

Ryzen主系サーバーと、ROCK 3BのNixOS構成。

- [要件・ロードマップ](requirements-and-roadmap.md)
- [ROCK 3B基本構成の移行](docs/rock3b-migration.md)
- [Ryzen SSD・RAID復旧手順](docs/ryzen-storage-recovery.md)
- [Nix Remote Builderの適用・運用手順](docs/nix-remote-builder.md)
- [Nix Binary Cache・12時間ごとの更新計画](docs/nix-binary-cache.md)
- [Forgejoの移行・公開手順](docs/forgejo-migration.md)
- [Actions Runnerの登録・Web CI確認手順](docs/forgejo-runner.md)
- [Ryzen Webデプロイ・公開切替手順](docs/web-deployment.md)

Phase 4のForgejo移行は2026-09-29に実用上完了。ROCK本体停止試験は未実施、
ROCK実機への適用は保留。基本構成のみ本リポジトリへ移植済み。
Phase 5はRyzen RunnerでWebビルドとCI失敗時の本番維持を確認済み。
Phase 6は2026-09-29に完了。DNS切替後の公開アクセス、実機でのビルド失敗時の
release維持、復旧後の正常デプロイと公開`/healthz`を確認済み。
Phase 7はBinary Cache基盤の公開・署名付きprobe取得、laptop設定適用、Forgejoへの正本移行を確認済み。
専用Nix Runnerの初回CI成功とlaptopでのキャッシュ利用を利用者が確認済み。
2026-10-06 09:00 JSTの初回定期実行は成功。fish補完を含むキャッシュ利用の恒久設定・適用も確認済み。
retention設定と成功statusの公開ログリンク修正が残る。

```text
flake.nix
hosts/ryzen/           ホスト設定・ディスク・ハードウェア
hosts/rock3b/          ROCK 3Bの起動・ハードウェア・bond・管理SSH
assets/edid/          ROCK 3BのHDMI用EDID
modules/system/       SSH・Mesh・保守・管理ユーザー
tests/forgejo.nix       Forgejo移行・起動抑止・Mesh SSH制限の試験
tests/web.nix           nginx・healthz・公開release切替の試験
tests/nix-cache.nix     署名付きcache・closure取得・障害時buildの試験
tests/nix-cache-update.py 定期更新のpush抑止・Git競合の回帰試験
```

`nixpkgs`は既存の`~/nixos-config`と同じrevisionから開始し、`flake.lock`で固定。
ROCK 3Bは基本構成のみ移植し、既存のサーバー機能は引き継がない。
実機への適用は別途行う。移行元の`~/nixos-config`は変更していない。

## 開発・検証

```sh
nix develop
nix fmt
statix check .
deadnix --fail .
nix flake check
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
nix build .#rock3b-image --out-link result-rock3b-image
```

ROCKのNVMe用イメージは`result-rock3b-image/rock3b-nvme.img`に生成する。
設定済みのU-Bootを利用する。詳細は[移行メモ](docs/rock3b-migration.md#nvme用イメージ)を参照。

`nix flake check`は使い捨てVMでForgejoの移行前の起動抑止、データ・鍵の引き継ぎ、
新しいclone URL、定期dump、Mesh経由だけのGit SSH接続を確認する。
Web公開releaseの切替と、Binary Cacheの署名付きclosure取得・別鍵での拒否・障害時ビルドも確認する。
x86_64 LinuxとKVMが必要。実機のディスクにはアクセスしない。
新しいファイルを追加した場合は、flakeから参照できるようGitに追加する。
ビルド・検証コマンドは現在のホストへ設定を適用しない。
