# Forgejo移行（Phase 4）

設定は `hosts/ryzen/forgejo.nix`。Forgejo 16.0.5 / SQLiteを維持して
ROCKの `/var/lib/forgejo` をRyzenの `/srv/forgejo` へ移行済み。

## 実施結果（2026-09-29）

**実用上のPhase 4移行は完了。受入条件のうちROCK本体停止試験のみ未実施。**

- RyzenへのNixOS設定適用、Tunnel認証JSON配置、停止コピーによるデータ復元を実施。
- Forgejoのactive状態とAPIのバージョン`16.0.5`を確認。
- `git.floating-gate.com`を公開し、既存アカウントでのログイン・リポジトリ表示を確認。
- Mesh経由のGit SSH認証、clone/push/pull、GitHub push mirrorの同期成功を確認。
- 定期dumpは`Result=success`、`ExecMainStatus=0`。
  `forgejo-dump-1790664217.tar.zst`（約11MB、9月29日15:43）を作成し、
  次回9月30日03:30 JSTの実行予約を確認。

laptop側では`~/nixos-config`の`93f5be4`で、Forgejoのホスト公開鍵固定と
Mesh接続用の個人鍵指定をコミットした。生成したSSH設定・固定公開鍵で参照取得に成功。
NixOSへの適用完了は未確認。
Forgejoをoriginに持つ既存リポジトリ`~/Projects/floating-gate`は、
`ssh://git@ryzen.home.arpa:2222/jinji/floating-gate.git`へ変更済み。

未実施・保留事項:

- ROCK本体停止中のWeb・Git利用試験。確認済みなのはROCKのForgejo等を停止した状態での利用。
- ROCK側の自動起動無効化・設定整理は利用者の方針で保留。
  停止操作だけでは再起動後の起動を防げないため、旧Forgejoの二重稼働に注意する。
- ROCKの既存Runnerは停止したまま、接続先更新・再開は未実施。Runner移行はPhase 5へ引き継ぐ。
- 定期dumpからの復元試験と別ホストへの暗号化バックアップ。
  今回復元した停止コピーのアーカイブと、定期dumpは別のバックアップである。

以下は移行手順の記録。現在稼働中の`/srv/forgejo`へ古いデータを上書きしない。

| 項目 | 移行後 |
| --- | --- |
| Web | `https://git.floating-gate.com/` |
| HTTP待受 | `127.0.0.1:3000`（Tunnelから直接接続） |
| Git SSH | `ssh://git@ryzen.home.arpa:2222/jinji/<repo>.git` |
| Meshアドレス | `100.96.0.1` |
| 管理SSH | 既存の22番を維持 |
| 保存先 | `/srv/forgejo` |
| dump | `/var/backup/forgejo`、毎日03:30、tmpfilesで30日保持 |

SSHはIPv4で待ち受け、firewallでMeshの送信元 `100.96.0.0/12` から
Ryzenの `100.96.0.1:2222` への通信だけを許可する。
クライアントでは既存のMesh接続と `ryzen.home.arpa` の名前解決を使う。
Cloudflare Access SSH用のProxyCommandは使用しない。

## 1. Tunnelを準備する

Ryzen専用のlocally managed Tunnel `ryzen-homelab` は作成済み。
UUIDは `aa088497-b776-4cb2-989e-935dc02ed6b3` で、設定ファイルに反映済み。
既存ROCKのTunnel UUIDは再利用しない。以下の `<UUID>` はこの値に置き換える。
必要な一時ツールは `nix shell nixpkgs#cloudflared` で利用できる。
認証JSONやアカウント証明書はGitへ追加しない。
Ryzenに専用の `<UUID>.json` をroot所有・0600で
`/var/lib/cloudflared/<UUID>.json` として配置する（親ディレクトリは0700）。
`cert.pem` はRyzenの実行用には不要。認証JSONはsystemdのLoadCredentialで渡す。

DNSはまだ切り替えない。Tunnelは次の起動マーカーと認証JSONが揃うまで起動しない。

## 2. 設定を検証・適用する

```sh
nix develop
nix fmt
statix check .
deadnix --fail .
nix flake check
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
```

実機への適用は、実施する時点で以下を手元から実行する。

```sh
nixos-rebuild switch --flake ~/servers-config#ryzen \
  --build-host jinji@ryzen.home.arpa \
  --target-host jinji@ryzen.home.arpa \
  --ask-sudo-password
```

`/srv/forgejo/.migration-ready` がなければForgejo、秘密情報生成サービス、
dumpサービス・タイマーは起動しない。先に空のインスタンスを作らないための仕組み。
マーカーだけ作っても、移行元のDBと必須の鍵ファイルが不足していれば起動は失敗する。

## 3. ROCKのサービスを停止してコピーする

Actionsの実行が終了したことを確認し、以降は移行完了までpushやUIでの更新を止める。
ROCKでRunner、dumpタイマー・サービス、Forgejoの順に停止する。

```sh
sudo systemctl stop gitea-runner-floatinggate.service
sudo systemctl stop forgejo-dump.timer forgejo-dump.service
sudo systemctl stop forgejo.service
systemctl is-active forgejo.service gitea-runner-floatinggate.service forgejo-dump.timer
```

すべてinactiveであることを確認してから保存する。

```sh
sudo install -d -m 700 /home/jinji/forgejo-migration
sudo tar -C /var/lib/forgejo -cpf /home/jinji/forgejo-migration/forgejo.tar .
sudo chown -R jinji:users /home/jinji/forgejo-migration
chmod 600 /home/jinji/forgejo-migration/forgejo.tar
sha256sum /home/jinji/forgejo-migration/forgejo.tar
```

アーカイブには秘密情報も含む。秘密情報を出力したりGitへ追加したりしない。
ROCKの元データを残したまま、手元を経由してSSHで転送する。

```sh
install -d -m 700 ~/forgejo-migration
scp ssh.floating-gate.com:forgejo-migration/forgejo.tar ~/forgejo-migration/
ssh jinji@ryzen.home.arpa 'install -d -m 700 ~/forgejo-migration'
scp ~/forgejo-migration/forgejo.tar jinji@ryzen.home.arpa:forgejo-migration/
```

## 4. Ryzenで復元する

RyzenでチェックサムがROCKの値と一致することを確認する。
Forgejoが停止中で、`/srv/forgejo` に既存の運用データがない場合に限り展開する。

```sh
sha256sum ~/forgejo-migration/forgejo.tar
sudo tar --no-same-owner -xpf ~/forgejo-migration/forgejo.tar -C /srv/forgejo
sudo chown -R forgejo:forgejo /srv/forgejo
sudo systemd-tmpfiles --create --prefix=/srv/forgejo
```

tmpfilesでARM版の `conf/locale` リンクをRyzen版へ置き換える。
起動時にapp.iniとGit hooksはNixOSモジュールが再生成する。
既存のsecret_key、各JWT秘密鍵、internal_token、SSHホスト鍵は保持する。

ROCKのForgejoが停止したままであることと、コピーの完了を確認してからマーカーを作る。

```sh
sudo install -o root -g root -m 600 /dev/null /srv/forgejo/.migration-ready
sudo systemctl reset-failed forgejo.service forgejo-secrets.service
sudo systemctl start forgejo.service
curl --fail http://127.0.0.1:3000/api/v1/version
```

起動に失敗した場合は、不足した鍵を新規生成して回避せず、コピー内容を確認する。
移行元の鍵は暗号化済みmirror認証情報などの利用にも必要。

## 5. 検証して公開する

既存アカウント、リポジトリ、Issue、LFS、Git SSHのclone/push/pull、
GitHub push mirrorの同期を確認する。Git SSH初回接続では、移行した内蔵SSHホスト鍵の
フィンガープリントを確認する。管理SSHのホスト鍵とは別の鍵である。
DNS切替前のWeb確認には、SSHポート転送とHTTP Host指定などで直接originを確認できる。
認証画面を含む本番URLでの確認は公開後にも行う。

Ryzenの `cloudflared-tunnel-<UUID>.service` を開始し、手元でDNSを登録する。

```sh
cloudflared tunnel route dns <UUID> git.floating-gate.com
```

既存DNSレコードがある場合は内容を確認してから変更する。
Cloudflare Accessを使用する場合は新hostname用のポリシーも用意する。
`https://git.floating-gate.com/` でログインと操作を確認する。
旧URLからの自動リダイレクトはこの設定には含まない。

```sh
git remote set-url origin ssh://git@ryzen.home.arpa:2222/jinji/<repo>.git
```

既存RunnerをROCKで再開する場合は、停止したまま接続先を更新してから再開する。
ROCK上のlocalhost:3000は移行後には利用できない。
Runnerの登録状態が引き継がれているか確認し、必要な場合だけ再登録する。
今回はROCK側の変更を保留し、Runnerの移設をPhase 5で行う。

Ryzenで `sudo systemctl start forgejo-dump.timer` を実行し、dumpと復元を検証する。
定期dumpは稼働中に取得するため、今回の停止コピーと同じ整合性を保証しない。
DB・Git・LFSを同一時点で復元する必要がある場合は停止バックアップを取る。
別ホストへの暗号化バックアップは保存先が未定のため未実装。

ROCK側の設定整理を再開する際は、Forgejoとdumpの自動起動をNixOS設定から無効化する。
既存Tunnelは管理SSH・Webサイトにも使われるため停止しない。
ROCK本体停止中のForgejo利用試験は残る受入条件として追跡する。

## 切り戻し

Ryzenで実データの更新を受け付ける前なら、RyzenのForgejo・dumpタイマー・専用Tunnelを
停止し、マーカーを除去してからROCKを再開する。クライアント・RunnerのURLとDNSも戻す。
新hostnameへ切り替えた場合、DNSだけ戻してもROCKの旧ingressには一致しないため、
旧hostnameへ戻すかROCK側のingressも合わせる。

Ryzenで更新を受け付けた後はROCKの古いデータをそのまま再開しない。
書き込みを停止し、最新のデータを戻す作業が必要。
両方のForgejoを同時に起動してGitHub mirrorやRunnerを動かさない。
