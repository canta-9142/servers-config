# Nix Binary Cache運用計画（Phase 7）

2026-10-05時点。署名付きファイルキャッシュのサーバー設定・公開コマンド・laptop設定を実装済み。
実機への適用、署名鍵の生成、DNS設定、端末間の取得確認は未実施。
定期更新ジョブ、retention、`nixos-config`の正本移行は後続作業。
既存のRemote Builder運用は[こちら](nix-remote-builder.md)を参照。

## 目的

Ryzenでlaptop用のNixOS構成を事前ビルドし、laptopの`nh os switch`での
ビルド待ちを減らす。Binary Cacheの設置だけでは事前ビルドは行われないため、
構成全体をビルドするCIと成果物公開を組み合わせる。

`*_fish-completions`などの生成物も、完成したシステムの実行に必要な依存一式
（closure）に含めて公開する。個別packageだけのビルド・公開では、
laptop固有の構成生成物まで揃うとは限らない。

キャッシュと一致する構成では、laptopが構成を評価し、ローカルにない成果物を
取得して適用する。サービス再起動等の適用処理はlaptopで実行する。

## リポジトリと更新の担当

- laptopの`~/nixos-config`の正本をRyzenのForgejoへ移す。
- laptopの`~/nixos-config`はそのcloneとして維持し、設定変更をpushする。
- Ryzenの更新ジョブも同じリポジトリを使用する。
- `servers-config`はサーバー構成のリポジトリとして引き続き分けて管理する。
- 既存リモートを残す場合は、バックアップ用mirrorとして扱う。

再利用には`flake.lock`だけでなく、設定ファイル、対象ホスト、ビルドに影響する
入力も一致する必要がある。同じコミットのlaptop構成をCIと手元で使用する。

## 12時間ごとの更新

Ryzenで12時間に一度、次の順序で更新を準備する。

1. Forgejoから最新の`nixos-config`を取得し、対象コミットを固定する。
2. `nix flake update`で`flake.lock`を更新し、更新コミットをローカルに作成する。
3. そのコミットのlaptop構成全体をビルドする。
4. 完成したシステムとclosureを署名付きBinary Cacheへ公開し、取得可能であることを確認する。
5. 成功した更新コミットだけをForgejoへpushする。

ビルドやキャッシュ公開に失敗した場合は更新コミットをpushせず、前回成功した
更新を維持する。公開後にブランチが進んでpushできなかった場合は強制pushせず、
最新の設定を取り込んで再ビルドする。設定変更のpushと定期更新の競合で、
未検証の組み合わせを公開しない。

設定変更のpushでもlaptop構成をビルド・公開する。
手動変更はpush時点では未ビルドなので、laptopで取り込む前に対象コミットの
CI成功を確認する。定期ジョブ自身のpushによるCIの重複実行・更新ループを避ける
具体的なトリガー設定は実装時に決める。

## laptopでの操作

対象コミットのCI成功を確認してから実行する。`NH_FLAKE`は既存の
`~/nixos-config#nixos`を使う。

```sh
cd ~/nixos-config
git pull --ff-only
nh os switch
```

通常は`--update`を付けない。手元の未コミット変更やCIより先のlock更新があると、
キャッシュと一致しない成果物のビルドが必要になる。
CIは自動でlaptopへ適用せず、適用のタイミングは利用者が決める。

キャッシュにない成果物は既存のRemote Builder運用でビルドする。
Ryzen自体が利用できない場合は、既存の手動ローカルビルド手順を使う。
キャッシュ接続障害時にもビルドへ進める設定・挙動を実装時に検証する。

## 導入と確認

- Forgejoへ`nixos-config`の履歴を移し、laptopのoriginを切り替える。
- RyzenにCache serverと署名鍵を用意し、laptopに取得先と信頼する公開鍵を設定する。
- 読み出しはCloudflare Tunnel経由のHTTP、書き込みはRyzenのCIまたは内部ネットワークで行う。
- laptop構成のCIと12時間ごとの更新を接続する。
- Nix StoreのGCとCacheのretentionを別管理し、現在利用中の構成と最近の世代を保持する。
- 同じコミットの構成が、fish completionsを含めてキャッシュから取得されることを確認する。
- 更新失敗時に更新コミットが公開されないこと、キャッシュ停止時のビルド手順を確認する。

キャッシュはNix標準のファイルキャッシュをnginxで配信する。
実行時刻、ブランチ構成、ジョブの認証・権限、retentionの具体的な期間は後続実装時に決める。

## キャッシュ基盤の適用手順

以下は利用者が実機で実行する手順。構成のビルドだけではサービスやDNSは切り替わらない。

### 1. Ryzenへの設定適用と署名鍵の生成

Ryzenで更新した`servers-config`を取得し、ビルド・適用する。

```sh
cd ~/servers-config
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
nh os switch
```

適用により`/srv/nix-cache`（root所有、0755）と`/var/lib/nix-cache`（root所有、0700）を作成する。
秘密鍵は後者に置き、Nix StoreやGitへ格納しない。以下は初回のみ実行する。
既存の鍵や公開鍵がある場合は上書きせず、既存のペアを確認する。

```sh
sudo bash <<'SH'
set -euo pipefail
umask 077
test ! -e /var/lib/nix-cache/signing-key
test ! -e /etc/nix/cache.floating-gate.com.pub
nix key generate-secret --key-name cache.floating-gate.com-1 > /var/lib/nix-cache/signing-key
nix key convert-secret-to-public < /var/lib/nix-cache/signing-key > /etc/nix/cache.floating-gate.com.pub
chmod 0644 /etc/nix/cache.floating-gate.com.pub
SH
```

秘密鍵の暗号化バックアップを別途保管する。紛失・漏洩時は新しい鍵を用意し、クライアントの信頼鍵を更新する。
nginxとcloudflaredは秘密鍵を読む必要がない。

### 2. 小さな成果物の公開

Ryzenで検証用成果物をビルドし、完成したstore pathを公開する。
検証用の非content-addressed derivationを使い、署名の検証対象を作る。

```sh
cd ~/servers-config
nix build --impure --expr 'let pkgs = (builtins.getFlake (toString ./.)).nixosConfigurations.ryzen.pkgs; in pkgs.runCommand "ryzen-cache-probe" {} "echo cache-probe > $out"' --out-link cache-probe
sudo nix-cache-publish "$(readlink -f cache-probe)"
curl --fail http://127.0.0.1:8081/nix-cache-info
```

`nix-cache-publish`はrootのみ実行可能で、指定したpathの実行時closureを
`/srv/nix-cache`へコピーし、公開時に署名する。引数なし・鍵なしでは失敗する。
公開はロックで直列化する。途中で失敗してもコピー済みの成果物は残るため、同じコマンドを再実行する。
cache-probeのsymlinkは確認後に削除してよい。

### 3. Cloudflareの公開経路

既存のRyzen Tunnel（`aa088497-b776-4cb2-989e-935dc02ed6b3`）には
`cache.floating-gate.com → http://127.0.0.1:8081`を構成済み。
Cloudflare DNSで`cache.floating-gate.com`を、このTunnelの
`aa088497-b776-4cb2-989e-935dc02ed6b3.cfargotunnel.com`へ向けるproxied CNAMEとして追加する。
このサブドメインにブラウザー向けAccessログインを要求しない。

```sh
curl --fail https://cache.floating-gate.com/nix-cache-info
```

nginxはloopbackのみで待ち受け、GET/HEADのみ許可する。ディレクトリ一覧は公開しない。
404のキャッシュが後の公開を妨げないよう`Cache-Control: no-store`を返す。
Cloudflareでこのホストのキャッシュを強制する既存ルールがある場合は除外する。
配信内容は公開情報となるため、秘密を含む成果物を公開しない。

### 4. laptopの信頼鍵と取得確認

laptopで、既存の固定済みSSHホスト鍵を使う管理SSH接続から公開鍵を取得する。
公開HTTP経由で取得した鍵を、そのまま信頼鍵にはしない。

```sh
cd ~/nixos-config
scp jinji@ryzen.home.arpa:/etc/nix/cache.floating-gate.com.pub hosts/laptop/nix-cache.pub
git add hosts/laptop/nix-cache.nix hosts/laptop/nix-cache.pub hosts/laptop/default.nix
```

`hosts/laptop/nix-cache.pub`は初期状態では空で、この間は新キャッシュ設定を有効にしない。
公開鍵を入れると取得先と信頼鍵が有効になり、既存のcache.nixos.orgとRemote Builderを維持する。
新キャッシュの優先度は50とし、標準キャッシュより後に問い合わせる。

Ryzenで得たcache-probeの絶対store pathを`PROBE_PATH`に設定して、
まずlaptopの既存Storeとは別の空のStoreへ取得する。
この検証はNixOS設定の適用を必要としない。

```sh
PROBE_PATH=/nix/store/ここをRyzenのcache-probeのpathに置き換える
PROBE_ROOT=$(mktemp -d)
nix copy --from https://cache.floating-gate.com \
  --to "local?root=$PROBE_ROOT" \
  --option trusted-public-keys "$(cat hosts/laptop/nix-cache.pub)" \
  "$PROBE_PATH"
cat "$PROBE_ROOT$PROBE_PATH"
```

`cache-probe`が出力されれば取得成功。確認後、検証用の`PROBE_ROOT`だけを削除する。
その後、通常の設定ビルド・適用を利用者が行う。

```sh
nix build .#nixosConfigurations.nixos.config.system.build.toplevel
nh os switch
```

キャッシュ取得失敗時は`fallback = true`でビルドへ進む。
Ryzenが起動していれば既存Remote Builderを利用する。Ryzenも停止している場合は
既存の`--builders '' --max-jobs 1`による手動ローカルビルドが必要。
HTTP障害時の待ち時間はNixの通信タイムアウト・再試行に依存する。

### 5. 現段階の保持と検証範囲

`/srv/nix-cache`はNix StoreのGCでは削除されない。一方、キャッシュの自動削除はまだ導入していない。
後続のretention導入までは公開量とディスク空き容量を監視する。
部分的な公開失敗は、CIの成功やlaptop構成の公開完了とは扱わない。

`nix flake check`には隔離VMでの基盤試験を追加している。
署名付きclosureの取得、別鍵での拒否、HTTP書き込み拒否、Store GC後の取得、
キャッシュ停止時のローカルビルドを確認する。
実機のTunnel、DNS、laptopのNixOS全closureとfish completionsの確認は別途必要。

2026-10-05に`nix flake check`（既存Forgejo・Web試験を含む）、Ryzen構成全体のビルド、
両リポジトリの静的チェックを確認済み。laptopは`nix flake check --no-build`で構成を評価し、
公開鍵が空の場合の無効化と、検証用公開鍵による設定有効化・既存取得先の維持を確認済み。
