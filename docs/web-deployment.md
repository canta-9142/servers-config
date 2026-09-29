# Ryzen Web Deployment（Phase 6）

## 構成

- nginxは`127.0.0.1:8080`で待ち受け、`/srv/www/floating-gate/current`を配信する。
- `releases/<commit SHA>`を公開単位とし、`.staging`で準備してから`current`をatomicに切り替える。
- `GET /healthz`は`current/index.html`がある場合に`200` / `ok`、未配置・欠損時は`503`を返す。
  初期のダミーreleaseは作らない。これは成果物の完全性検査ではなく、nginxと公開先の最低限の確認。
- 既存のRyzen Tunnel `aa088497-b776-4cb2-989e-935dc02ed6b3`に
  `floating-gate.com → http://127.0.0.1:8080`を追加する。DNSは別途切り替える。
  Tunnelの起動は既存のForgejo移行完了マーカーと認証JSONに依存する。
- `floating-gate`の`deploy.yml`は`main`のpushまたは手動実行で動作する。
  既存の`ryzen-web-build` Runnerで一度だけビルドし、その`dist`を公開する。
  `build.yml`の自動実行は`phase5-ci`のみとし、`main`の二重ビルドを避ける。
- 本番jobだけがサイト領域をrwマウントする。AlpineにGNU coreutils、findutils、
  util-linuxを入れ、既存`deploy.sh`の`mv -T`、`find -delete`、`flock`を利用する。
  20世代保持。同一commitの再実行は既存releaseを再利用する。

Runnerの登録変更や追加トークンは不要。ホスト全体のマウントやruntime socket公開は行わない。
ただし`valid_volumes`の許可はworkflow編集者にもサイトの読み書き権限を与える。
`main`の条件やRunnerラベルは権限境界ではないため、信頼する管理者のみがworkflowを変更できる
リポジトリで使う。外部PRをこのRunnerで自動実行する構成は追加していない。
詳細は[Forgejoのvolume権限説明](https://forgejo.org/docs/v15.0/admin/actions/security/#containervalid_volumes)を参照。

## ローカル検証

```sh
cd ~/servers-config
nix fmt
nix develop -c statix check .
nix develop -c deadnix --fail .
nix flake check
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel --no-link

cd ~/Projects/floating-gate
nix shell --inputs-from ~/servers-config \
  nixpkgs#bubblewrap nixpkgs#git nixpkgs#coreutils nixpkgs#findutils nixpkgs#util-linux \
  -c sh scripts/ci/test-deploy.sh
```

VM試験はnginxの配信、未配置時の503、release切替、再起動後の維持を確認する。
サイト側の試験はbubblewrap内の一時領域で実際の`deploy.sh`を実行し、
公開・同一commit再実行・成果物欠損・SHA不一致・コピー途中とコピー失敗時の旧release維持・
旧release整理を確認する。実サイトの`/srv`には書き込まない。

## 適用・初回デプロイ

以下は実機適用を行う段階で実施する。ローカルビルドだけでは本番は変わらない。

1. servers-configのPhase 6差分を確認し、Ryzenへ設定を適用する。

   ```sh
   nixos-rebuild switch --flake .#ryzen \
     --build-host jinji@ryzen.home.arpa \
     --target-host jinji@ryzen.home.arpa --ask-sudo-password
   ```

2. RyzenでnginxとRunnerの起動を確認する。
   初回デプロイ前の`curl -i http://127.0.0.1:8080/healthz`は503が正常。
3. サイトリポジトリの`deploy.yml`、`build.yml`、`test-deploy.sh`だけをレビューして
   `main`へ統合・pushする。既存の無関係な記事やlockfile変更を含めない。
   旧`node-22`向けdeployを残さず、新しい`deploy.yml`に置き換える。
   Phase 5の最終build workflow相当はローカルに反映済みで、ブランチ全体のmergeは不要。
4. CI成功後、Ryzenで以下を確認する。

   ```sh
   readlink /srv/www/floating-gate/current
   curl -fsS -H 'Host: floating-gate.com' http://127.0.0.1:8080/
   curl -fsS -H 'Host: floating-gate.com' http://127.0.0.1:8080/healthz
   ```

   `current`がCIのcommit SHAを指し、HTMLと`ok`が返ること。
   Runnerコンテナからのrwマウント、Alpineのツール、Podman制限の維持も実機CIで確認する。
5. 公開切替前に、合意した試験commitでビルドを意図的に失敗させ、
   前後の`current`と`index.html`のハッシュが一致することを確認する。試験commitを戻し再成功を確認する。

## 公開先の切替

Ryzenの初回デプロイと受入確認後、Cloudflareの`floating-gate.com`のDNSレコードを
Ryzen Tunnelの`aa088497-b776-4cb2-989e-935dc02ed6b3.cfargotunnel.com`へ変更する。
変更前のROCK宛先を控える。ROCKのTunnel、nginx、既存releaseは残す。

公開URLの本文と`/healthz`を確認し、Ryzenのnginxアクセスログにも到達が記録されることを確認する。
Cloudflare側でHTMLをキャッシュするルールがあれば、キャッシュを消して確認する。
問題時はDNSを元のROCK Tunnelへ戻す。この時点ではROCKの内容は更新されないため、
戻した場合はROCKに最後にデプロイされた内容になる。

DNS切替はPhase 10の自動failoverではない。二重デプロイはPhase 9、Load BalancingはPhase 10で扱う。

## 以前のreleaseへ戻す

CIの実行が終了していることを確認し、Ryzenで残っているrelease SHAを指定する。
CIと同じロックを使い、リンクだけを切り替える。

```sh
sudo sh -eu <<'SH'
cd /srv/www/floating-gate
release=REPLACE_WITH_EXISTING_COMMIT_SHA
exec 9>.deploy.lock
flock -x 9
test -f "releases/$release/index.html"
temporary=$(mktemp -d .staging/rollback.XXXXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
ln -s "releases/$release" "$temporary/current"
mv -Tf "$temporary/current" current
SH
```

次回の正常CIは再びそのcommitを公開する。release整理は公開後に行うため、整理だけが失敗した場合は
CIが失敗表示でも公開リンクが切り替わっていることがある。ログと`current`を確認する。

## 状態

2026-09-29に以下を確認済み。

- `nix fmt`、`statix check`、`deadnix --fail`、`git diff --check`
- `nix flake check`（既存Forgejo VM試験・追加Web VM試験）
- Ryzenのsystem toplevelビルド
- デプロイ試験（bubblewrapおよびローカルPodmanの`node:22-alpine`）
- `shellcheck`（deploy・テストスクリプト）、`actionlint`（両workflow、独自Runnerラベルを許容）

実機適用と初回デプロイは2026-09-29に完了。
サイト側の`9dbfeb72afbced0ce74fd1fc5c7884d24aa8585e`をリモート`main`へpushし、
[CI #77](https://git.floating-gate.com/jinji/floating-gate/actions/runs/77)が成功した。
Ryzenのnginx・Runnerがactiveで、Runnerのvolume許可がサイト領域に限定されていることを確認した。
`current`は同commitのreleaseを指し、`/healthz`は`200` / `ok`を返す。
HTTPで取得したHTMLと`current/index.html`のSHA-256はともに
`555e7c6695c4ed1e724b2d9da40649b9b698efbc7ae05a847a9b259f78399de2`で一致した。

ローカル`main`に未pushのRSSロゴ変更`923c534`があったため、`origin/main`を起点とする
`phase6-deploy` worktreeからPhase 6の3ファイルのみをpushした。
元の作業ツリーの未コミット変更とローカル`main`は維持している。
今後ローカル`main`からpushする前に、リモート側のPhase 6 commitを取り込む必要がある。

DNS切替後の公開アクセスは利用者が確認済み。下記の失敗・復旧試験も完了したため、Phase 6は完了。

## 実機の失敗・復旧受入テスト

`scripts/check-web-release.py`は読み取り専用の受入テスト。
期待するcommit SHAと`index.html`のSHA-256を指定し、以下をassertする。

- Ryzenの`current`、保存されたHTML、nginx経由のHTMLが期待値と一致する。
- Ryzenと公開URLの`/healthz`が正常応答し、本文が`ok`である。
- 公開HTMLも同一内容である。Cloudflareがリクエストごとに挿入する
  `/cdn-cgi/content`の隠しリンクとchallenge scriptのみ除外し、残りはバイト単位で比較する。
  クエリと`Cache-Control: no-cache`でキャッシュの影響を抑える。

```sh
cd ~/servers-config
nix shell --inputs-from . nixpkgs#python3 -c python3 scripts/check-web-release.py \
  557c62cdacf7001e3b769287baf43cc90fda3dcd \
  555e7c6695c4ed1e724b2d9da40649b9b698efbc7ae05a847a9b259f78399de2
```

上記は2026-09-29の復旧後の期待値。以後の正常デプロイでは期待するSHAを更新する。
再試験時はまず現行releaseを指定して成功を確認する。
サイトの`package.json`の`scripts.build`を、一時的に
`node -e "throw new Error('Phase 6 intentional build failure')"`へ置換してmainにpushする。
通常のdeploy workflowのビルドが失敗した後、同じ期待値で再度このテストを実行する。
試験commitを必ずrevertしてpushし、CI成功後に新commit SHAでテストする。
試験用の失敗分岐は本番workflowやbuildスクリプトに常設しない。

実施結果:

| 実行 | commit | 結果 |
| --- | --- | --- |
| 試験前 | `9dbfeb7` | release・origin・公開HTMLと両healthzが正常 |
| [CI #78](https://git.floating-gate.com/jinji/floating-gate/actions/runs/78) | `c7dd68f` | npm buildが意図したErrorでexit 1。旧`9dbfeb7`を維持し、同じ受入テストが成功。失敗commitのreleaseは作成されなかった |
| [CI #79](https://git.floating-gate.com/jinji/floating-gate/actions/runs/79) | `557c62c` | 失敗変更をrevertしCI成功。新release・origin・公開HTMLと両healthzが正常 |

試験前・失敗後・復旧後のHTML SHA-256はすべて上記の値で一致。
`557c62c`のソースツリーは試験前の`9dbfeb7`と同一で、意図的な失敗変更は残っていない。
元のローカルmainと未コミット変更は保持し、実機試験用worktreeからpushした。
