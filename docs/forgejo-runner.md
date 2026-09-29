# Actions Runner（Phase 5）

以下はPhase 5時点の構成・受入記録。
Phase 6でサイト領域のvolume許可と本番workflowを追加した。
現在の適用手順・権限の前提は[Webデプロイ手順](web-deployment.md)を参照。

Ryzenの`hosts/ryzen/runner.nix`でWebビルド専用Runnerを構成する。
対象は`~/Projects/floating-gate`の`.forgejo/workflows/build.yml`。
Nix build用workflowは今回スキップし、本番デプロイはPhase 6で追加する。

## 構成

- Runner名: `ryzen-web-build`、ラベル: `ryzen-web-build`
- サービス: `gitea-runner-web.service`
- Forgejo接続: `http://127.0.0.1:3000`
- jobのcheckout: `https://git.floating-gate.com`
- Podman上の`node:22-alpine`、同時実行1件、30分制限
- jobのDNSは`1.1.1.1` / `1.0.0.1`。PodmanブリッジのTCP/UDP 53だけをfirewallで許可
- jobコンテナ: メモリ4 GiB、CPU 2上限
- 特権実行なし、ホストvolume許可なし、runtime socket共有なし
- 公開ディレクトリのmount・`site-deploy`グループへの所属なし

コンテナの制限は本番との資源競合を軽減するが、同一ホストでの完全な資源分離を
保証するものではない。ディスク・ネットワークは共有する。
`docker_host = "-"`はjobへのsocket共有を抑止する設定。
[ForgejoのRunnerセキュリティ説明](https://forgejo.org/docs/v15.0/admin/actions/security/)も参照。

Podman 5.8.7ではDebianの絶対symlink `/var/run -> /run`を通るactionのコピーが失敗するため、
相対symlinkを使うAlpineを採用する（[上流issue](https://github.com/podman-container-tools/podman/issues/29805)）。
workflowは`sh`を使い、checkout前に`apk add --no-cache git`を実行する。
WARPのホスト専用loopback DNSを使わず、公開DNSを指定する。
Podmanはjobのresolverをブリッジ上のaardvarkへ向けるため、DNSポートの受信許可も必要。

## 登録・適用

1. Forgejoの`floating-gate`リポジトリのSettings → Actions → Runnersから
   登録トークンを取得する。リポジトリ単位のRunnerとして登録する。
2. Ryzenで`sudo install -d -m 700 /etc/forgejo-runner`を実行し、
   `sudo install -m 600 /dev/null /etc/forgejo-runner/web.env`で新規ファイルを作る。
   **既存ファイルがある場合はこのinstallを再実行しない。**
   `sudoedit /etc/forgejo-runner/web.env`で`TOKEN=<登録トークン>`の1行を保存する。
   トークンはGit・コマンド履歴・チャットへ記載しない。
3. 設定を検証して適用する。

```sh
cd ~/servers-config
nix develop
nix fmt
statix check .
deadnix --fail .
nix flake check
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
nixos-rebuild switch --flake .#ryzen \
  --build-host jinji@ryzen.home.arpa \
  --target-host jinji@ryzen.home.arpa \
  --ask-sudo-password
```

トークンまたはForgejoの移行完了マーカーがない場合はRunnerの起動をスキップする。
後から配置した場合は`sudo systemctl start gitea-runner-web`を実行する。
登録状態は`/var/lib/gitea-runner/web`に保存される。ROCKの登録状態はコピーしない。
トークン・ラベルの変更時はNixOSモジュールが再登録する。

## Web CIの受入確認

既存`deploy.yml`は`main`へのpushで本番公開まで行うため、初回は
`phase5-ci`ブランチに新しい`build.yml`を含めてpushする。
ローカルの未コミット変更を巻き込まず、必要な変更だけコミットする。
このブランチでは既存deploy workflowは起動しない。
新Runnerは既存の`node-22`ラベルのjobを引き受けない。

1. ForgejoでRunnerがonline、ラベルが`ryzen-web-build`であることを確認する。
2. `phase5-ci`へのpushでcheckout、依存関係のインストール、Astro buildが成功することを確認する。
   `build.sh`は`dist/index.html`の存在も検証する。
3. 同ブランチのbuild job末尾に一時的な`run: exit 1`のstepを加えてpushし、
   CIが失敗しても公開サイトと本番`current`リンクが変わらないことを確認する。
   確認後は失敗用stepを削除する。
4. 追加の停止試験として、`sudo systemctl stop gitea-runner-web`中もForgejoと公開サイトが利用可能なことを確認し、
   `sudo systemctl start gitea-runner-web`で再開する。

checkoutにはコンテナから新しい公開URLへの到達が必要。
Cloudflare Accessのログイン画面が返る場合は、CI用の認証経路を整えてから再試行する。
Phase 5ではartifactの永続保存・公開・Nix buildは行わない。
既存deploy workflowの旧checkout URLとRyzenへのデプロイ対応はPhase 6で変更する。

## 検証状況

ローカルの一時コピーで、`nix develop`のNode 22から既存のinstall/buildスクリプトを
実行し、15ページと`dist/index.html`の生成を確認済み。
`statix check`、`deadnix --fail`、`nix flake check`（既存Forgejo VM試験）、
Ryzenのsystem toplevelビルド、新workflowの`actionlint`も成功。
2026-09-29に初回の実機適用・Runner登録が完了し、Forgejo公開URLも復旧した。
`phase5-ci`のクリーンなソースでローカルビルド成功を確認済み。
[CI #70](https://git.floating-gate.com/jinji/floating-gate/actions/runs/70)でPodmanのsymlink問題、
Alpineへ変更した#71〜#73でブリッジDNSのタイムアウトを確認した。
#73では外部DNS `1.1.1.1`への直接問い合わせが成功し、ブリッジ`10.89.0.1`は失敗した。
RunnerのAlpine・公開DNS指定とブリッジDNS許可を再適用済み。

- [CI #74](https://git.floating-gate.com/jinji/floating-gate/actions/runs/74): checkout・依存関係取得・15ページ生成が成功。
- [CI #75](https://git.floating-gate.com/jinji/floating-gate/actions/runs/75): 公開ディレクトリとruntime socketがなく、
  メモリ4 GiB・CPU 2のcgroup制限が有効なことを検証後、意図的に`exit 1`で失敗。
  前後でROCKのnginxはactive、公開releaseは`439bd352ee9c157fad998ace8836515d4e44d058`のまま、
  `index.html`のSHA-256も`555e7c6695c4ed1e724b2d9da40649b9b698efbc7ae05a847a9b259f78399de2`で一致。
  公開サイトとForgejoの提供を継続した。
- [CI #76](https://git.floating-gate.com/jinji/floating-gate/actions/runs/76): 意図的失敗stepを削除した`ed3cfc5`で再度成功。

WebビルドとCI失敗時の本番維持の受入は完了。Runner停止試験は未実施。
workflowはリモートの`phase5-ci`ブランチにあり、`main`にはまだ統合していない。
ローカルの`~/Projects/floating-gate/.forgejo/workflows/build.yml`にも最終版を配置済み。
`main`へのpushは既存の本番deployも起動するため、Phase 6のデプロイ構成整理と合わせて統合する。
