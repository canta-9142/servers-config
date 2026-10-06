# Nix Binary Cache運用計画（Phase 7）

2026-10-06時点。署名付きファイルキャッシュのサーバー設定・公開コマンド・laptop設定を実装済み。
基盤の実機適用・署名鍵生成・DNS設定・署名付きprobe取得を確認済み。laptopへの設定適用も利用者が確認済み。
`nixos-config`のoriginはForgejoへ切替済みで、移行時のmain（`4f29345`）の一致を確認した。
専用Runnerの初回CI成功とlaptopでのキャッシュ利用を利用者が確認済み。
12時間ごとの定期更新を実装済みで、実機での初回実行は未実施。retentionは後続作業。
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

設定変更のmainへのpushでもlaptop構成をビルド・公開する。
手動変更はpush時点では未ビルドなので、laptopで取り込む前に対象コミットの
CI成功を確認する。定期ジョブ自身のpushは`[skip ci]`で通常CIを抑止する。
更新コミットには`Nix cache / lock update`という成功statusと、検証した定期実行へのリンクを付ける。

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

`hosts/laptop/nix-cache.nix`で`always-allow-substitutes = true`を設定する。
fish補完などの`allowSubstitutes = false`な生成物もキャッシュ取得の対象になる。
この設定を初めて適用する際は`nh os switch -- --always-allow-substitutes`を使う。
2026-10-06に、同じ構成のdry-runがビルド85件から0件・取得39件に変わることを確認し、
利用者から実機での高速化も確認された。

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

## 設定push時のCI

### 構成と権限

`hosts/ryzen/nix-ci.nix`に、`nixos-config`リポジトリ専用のRunnerを追加した。

- Runner名・ラベル: `ryzen-nix-build`（`host`実行）
- サービス: `gitea-runner-nix.service`、実行ユーザー: `nix-ci`
- 登録用token file: `/etc/forgejo-runner/nix.env`
- 登録状態・job workspace: `/var/lib/gitea-runner-nix`（0700）
- 同時実行1件、Runner側8時間・workflow側6時間の制限
- Bash、Git、Node.js 22、NixをホストPATHへ追加
- Nix daemonを利用する。`nix-ci`を`trusted-users`や`wheel`には追加しない。
- sudoは`/run/current-system/sw/bin/nix-cache-publish`だけをパスワードなしで許可する。

Web Runnerとはユーザー・登録状態・ラベルを分ける。ジョブはコンテナではなくホストで実行するため、
このRunnerは信頼する`nixos-config`リポジトリだけに登録し、workflowの編集権限を管理する。
workflow作者は`nix-ci`としてホスト上でコードを実行でき、有効なStore pathを署名・公開できる。
署名鍵そのものやrootの任意コマンドへのアクセスは許可しない。
[Forgejoのhost実行とラベルの説明](https://forgejo.org/docs/latest/admin/actions/configuration/#host)も参照。

公開コマンドはstore hashを含む絶対pathだけを許可し、`nix-store --check-validity`で
既存成果物であることを確認する。rootとしてflakeを評価・ビルドしない。
Nixビルドはdaemon側で実行されるため、RunnerサービスのCPU・メモリ制限だけでは
ビルド資源を制限できない。workflowはビルドの`--max-jobs 1 --cores 8`を指定する。
他のRemote Builder利用者との資源競合は残る。

### workflowの動作

laptopリポジトリの`.forgejo/workflows/nix-cache.yml`を使う。
通常ビルドは`main`へのpushと、`main`を対象にした手動実行（`update_lock = false`）を処理する。
PRや他ブランチでは実行しない。定期更新のscheduleと`update_lock = true`の手動実行は別jobで処理する。

1. 既存Web CIと同じrevisionに固定したcheckout actionで対象コミットを取得する。認証情報はGit設定に残さない。
2. checkout済みHEADがイベントのSHAと一致することを確認する。
3. `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`でlaptop構成全体をビルドする。
   lockは更新せず、flake側のキャッシュ設定は`--accept-flake-config`で受け入れる。
   Nix daemonの信頼設定を変更する権限はないため、未許可の追加キャッシュ設定は無視されることがある。
4. `result`の絶対pathをsudo経由の公開コマンドへ渡し、closure全体を署名・公開する。
5. 公開HTTPSのキャッシュを`nix store verify --no-contents --recursive --sigs-needed 1`で確認する。
   checkoutした公開鍵を使い、closure全体のメタデータと署名を検証する。

全stepが成功したときだけCI成功となる。ビルド失敗時は公開stepへ進まず、既存キャッシュを保持する。
公開や公開URLの確認に失敗した場合もCIは失敗とする。コピー済み成果物は消さず、再実行で再利用する。
同時実行は直列化し、進行中jobを新しいpushで中止しない。laptopへの適用・lock更新・Gitへのpushは行わない。
`result`は次回checkoutまでビルド成果物のGC rootになる。

`--no-contents`の確認はNARの全量ダウンロードを省略する。
ファイル本体の取得試験は後述のlaptop受入確認で別途実施する。

### Runner登録と適用

1. Forgejoの`jinji/nixos-config`でSettings → ActionsからActionsを有効にする。
2. 同リポジトリのSettings → Actions → Runnersで登録トークンを取得する。
   インスタンス全体や組織単位のRunnerにはしない。
3. Ryzenでtoken fileを初回作成する。既存ファイルがある場合は上書きしない。

```sh
sudo install -d -m 700 /etc/forgejo-runner
sudo test ! -e /etc/forgejo-runner/nix.env && sudo install -m 600 /dev/null /etc/forgejo-runner/nix.env
sudoedit /etc/forgejo-runner/nix.env
```

エディタで`TOKEN=<登録トークン>`の1行を保存する。値をGitやチャット、コマンド履歴に記載しない。

4. Ryzenで更新した`servers-config`を取得し、ビルド・適用する。

```sh
cd ~/servers-config
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
nh os switch
systemctl status gitea-runner-nix
```

token file、Forgejoの移行マーカー、署名鍵が揃うまでRunnerは起動しない。
設定適用後にtoken fileを作成した場合は、`sudo systemctl start gitea-runner-nix`を実行する。
ForgejoでRunnerがonlineで、ラベルが`ryzen-nix-build`であることを確認する。

5. laptopのworkflowとactionlint設定をコミットし、Forgejoの`main`へpushする。
   pushはCIでlaptop構成をビルド・公開するが、laptopを自動で再構成しない。

```sh
cd ~/nixos-config
nix shell nixpkgs#actionlint --command actionlint \
  -config-file .forgejo/actionlint.yaml .forgejo/workflows/nix-cache.yml
git add .forgejo/workflows/nix-cache.yml .forgejo/actionlint.yaml
git commit -m "ci: build and publish laptop NixOS closure"
git push origin main
```

### 初回受入確認

- 対象コミットのCIが成功し、ログに公開したsystem pathが表示されることを確認する。
- 同じコミットを使うlaptopで、そのsystem pathを先の`PROBE_ROOT`方式で空のStoreへ取得する。
  closureにはfish completions等の構成生成物も含まれる。空き容量と通信量を確認して実行する。
- 取得後に`nh os switch`を実行する。laptop固有の生成物がキャッシュから取得されることを確認する。
- 意図的なビルド失敗を確認する場合は、信頼するmainへのテストコミットで実施し、
  公開stepがスキップされることと既存キャッシュが取得できることを確認してからrevertする。
- Runnerの実機登録・初回CI・laptopでのキャッシュ利用は利用者が確認済み。意図的な失敗試験は未確認。

基盤VM試験は専用ユーザーのdaemon経由ビルド、制限付きsudoでの公開、
秘密鍵・root任意コマンド・不正な公開引数へのアクセス拒否と、公開closureの署名検証も確認する。
実際のRunner登録・checkout action・laptop構成全体のCIビルドは、このVM試験には含めない。

2026-10-05に拡張したVM試験を含む`nix flake check`、`statix`、`deadnix`、
Ryzen構成全体のビルドと、独自Runnerラベルを設定した`actionlint`が成功。

## 定期更新の導入と確認

### スケジュールと実行方式

同じ`.forgejo/workflows/nix-cache.yml`に`update-lock` jobを追加した。
`0 */12 * * *`（UTC）で毎日09:00・21:00 JSTに起動する。
Forgejoがdefault branchのworkflowからscheduleを登録し、既存のRyzen Runnerで実行する。
Runner待ちや長いビルドがある場合、実際の開始時刻は遅れる。
[Forgejoのschedule仕様](https://forgejo.org/docs/latest/user/actions/reference/#onschedule)を参照。

通常pushのビルドと同じconcurrency groupを使い、Runnerのcapacityも1のままとする。
ジョブは6時間でタイムアウトする。通常pushや通常の手動ビルドではlockを更新しない。
定期更新はschedule、またはmainを対象とした手動実行で`update_lock = true`を選んだ場合だけ動く。

### 更新・公開・push

Ryzenに`nix-cache-update`をインストールする。
処理本体は`servers-config/scripts/update-nix-cache.sh`で、CIの使い捨てcheckout内から実行する。
このコマンドは利用者の通常cloneでは実行しない。最初にtrackedな未コミット変更がないことを確認する。

1. 最新のorigin/mainをfetchし、対象SHAへdetached checkoutする。
2. flake inputsを更新し、差分がある場合は`flake.lock`だけをローカルでコミットする。
   作者は`nix-cache-updater`、メッセージは`chore: update flake.lock [skip ci]`。
3. そのコミットのlaptop構成全体をビルドし、既存のsudo公開コマンドでclosureを署名・公開する。
4. 公開HTTPSのclosureメタデータと署名を再帰的に検証する。
5. 更新コミットがある場合だけmainへ通常pushする。force pushや単なるrebaseでは競合を回避しない。
6. 実際に検証したコミットへ`Nix cache / lock update`の成功statusをAPIで登録し、定期実行のURLを付ける。

lockに差分がない場合も、最新構成のビルド・公開・検証は行い、新しいコミットは作らない。
これにより手動で初回実行する際、inputsに更新がなくても処理全体を確認できる。

ビルド・公開・署名検証のいずれかが失敗した場合、更新コミットはpushしない。
失敗時に新しくコピーできたキャッシュ成果物は残るが、未検証の更新コミットは公開しない。
通常pushが競合した場合は最新mainからlock更新・コミット・ビルド・公開・検証をすべてやり直す。
3回とも競合した場合は失敗として終了し、次回実行へ持ち越す。
mainが進んでいないpush失敗（認証・通信等）は、その場で失敗とする。
通信切断後に更新コミットがmainへ到達していたと確認できた場合は、status登録へ進む。

status APIだけが失敗した場合は、ビルド・公開・検証済みのコミットがpush済みである可能性がある。
未検証の更新ではないため巻き戻さず、ジョブを失敗とし、ログの対象SHAと公開結果を確認する。
次回、lockに差分がない場合も再検証・status登録を実行する。

### 認証と重複実行の抑止

新しいSSH鍵や長期PATは不要。checkout actionがジョブ限定の自動トークンをGit設定に保存し、
push時に使用する。status APIも同じトークンを使う。checkoutのpost-job処理で認証設定を削除し、
トークン自体もジョブ終了時に失効する。
[Forgejoの自動トークン](https://forgejo.org/docs/latest/user/actions/security/#automatic-token)を参照。

更新jobは`contents: write`と`statuses: write`を宣言する。
Forgejoでは実際の権限は自動トークンとリポジトリ設定にも依存するため、
初回実行でmainへのpushとstatus APIを確認する。mainの保護設定がある場合は、この書き込みを許可する必要がある。
トークンはjobの環境変数で渡し、scriptはxtraceを無効にして値をログへ出さない。

`[skip ci]`はForgejo 16.0.5の標準設定でpush時のworkflow実行を抑止する。
scheduleと手動実行は抑止しないため、lock更新のpushから更新ループを起こさない。
[標準のskip文字列](https://codeberg.org/forgejo/forgejo/src/tag/v16.0.5/modules/setting/actions.go)と
[イベント別の抑止処理](https://codeberg.org/forgejo/forgejo/src/tag/v16.0.5/services/actions/notifier_helper.go)を参照。
`SKIP_WORKFLOW_STRINGS`を独自設定する場合は`[skip ci]`を残す。

定期実行のActions画面は開始時点のSHAに関連付く。
laptopで更新を取り込む前には、新しいコミットの`Nix cache / lock update`成功statusとリンク先の実行結果を確認する。

### 適用と初回確認

1. Ryzenへ更新した`servers-config`を取り込み、ビルドして適用する。

```sh
cd ~/servers-config
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
nh os switch
test -x /run/current-system/sw/bin/nix-cache-update
```

2. laptopの更新workflowをコミットしてForgejoのmainへpushする。
   先にサーバー側コマンドを適用してからworkflowを公開する。

```sh
cd ~/nixos-config
nix shell nixpkgs#actionlint --command actionlint \
  -config-file .forgejo/actionlint.yaml .forgejo/workflows/nix-cache.yml
git add .forgejo/workflows/nix-cache.yml
git commit -m "ci: update and prebuild laptop inputs every twelve hours"
git push origin main
```

3. Actionsからmainを対象に手動実行し、`update_lock`をtrueにする。
4. lock更新・ビルド・公開・署名検証・push・status登録までの成功を確認する。
   差分がある場合、mainにはflake.lockだけを変更するコミットが増え、通常ビルドは重複起動しない。
5. 新コミットの成功statusを確認して、laptopで`git pull --ff-only`、`nh os switch`を実行する。
   次の09:00または21:00 JSTにschedule実行が起動することも確認する。

回帰試験は隔離したbare Gitリポジトリを使い、更新・ビルド・公開・検証失敗時のpush抑止、
差分なし、実際のnon-fast-forward競合と再ビルド、3回競合後の終了、push拒否、status失敗、
既存の未コミット変更の保持を確認する。Nixビルド・公開・APIだけはダミーコマンドで置き換える。
本番のトークン権限、skip-ci、schedule、最新inputsのlaptopビルドは実機の初回実行で確認する。

2026-10-06の実装時に、回帰試験8件、VMテストを含む`nix flake check`、
Ryzen構成全体のビルド、`statix`・`deadnix`・workflowの`actionlint`が成功。
本番への適用と定期更新workflowの初回実行は未実施。
