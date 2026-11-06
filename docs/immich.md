# Ryzen Immich

NixOSの`services.immich`でImmich・PostgreSQL（VectorChordを含む）・Redis・
機械学習サービスを管理する。バージョンは既存の`flake.lock`で固定する。
Cloudflare Mesh経由でのみ利用し、公開HTTP用Tunnelへの追加は行わない。

## 保存先と容量

| 対象 | 保存先 |
| --- | --- |
| 写真・動画・サムネイル・DBの自動dump | `/srv/immich` |
| PostgreSQL | NixOS標準の`/var/lib/postgresql`配下 |
| 機械学習モデルのキャッシュ | `/var/cache/immich` |

`/srv/immich`は`immich:immich`所有、0700で作成する。
PostgreSQL・Redisはローカル接続を使い、外部へポートを開けない。
顔認識・検索用のモデルは初回利用時にダウンロードされる。

当初の写真・動画は約50GB。生成データと増加分を含め、導入時は100GB程度の
空き容量を目安とする。これは予約・クォータではない。
`/srv`とNix Store・ビルドキャッシュは約500GBのRAID1を共有するため、
実機で`df -h /srv /nix`を確認する。16GB RAMをビルド処理と共有するため、
初回の大量取り込みは大規模ビルドと時間をずらして行う。

## 検証・適用

```sh
nix develop
nix fmt
statix check .
deadnix --fail .
nix build .#checks.x86_64-linux.immich
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel
```

VM試験では、起動・保存先の所有権・管理者作成・DB dump・手動バックアップからの復旧と、
Mesh送信元かつMesh宛ての通信だけが通ることを確認する。実際のCloudflareには接続しない。

実機で空き容量を確認してから、Ryzen上で適用する。

```sh
cd /home/jinji/servers-config
df -h /srv /nix
sudo nixos-rebuild switch --flake .#ryzen
systemctl status immich-server immich-machine-learning postgresql redis-immich
curl -fsS http://127.0.0.1:2283/api/server/ping
```

設定をビルド・コミットするだけでは、実機には適用されない。

## Meshからの利用

スマホ・PCを既存のCloudflare One組織へ接続し、Cloudflare One Clientを有効にする。
接続先は **`http://100.96.0.1:2283`**。ブラウザとImmichアプリで同じURLを使う。
Mesh内の経路はCloudflare One Clientが暗号化する。
`ryzen.home.arpa`が同じMesh IPへ解決される端末では、その名前でも接続できる。

ファイアウォールは送信元`100.96.0.0/12`・宛先`100.96.0.1`・TCP 2283の組み合わせだけを
許可する。LAN IP宛ての接続は許可しない。Mesh IPを変更した場合は、
`hosts/ryzen/immich.nix`のルールも更新する。
Cloudflare側でもSplit Tunnelsの対象経路とGatewayのネットワークポリシーが
この通信を許可している必要がある。

初回はブラウザから管理者を作成し、アプリでログインして少量の写真をアップロードする。
管理者の作成は利用者が行い、パスワードやAPIキーをNixファイルへ書かない。
Meshに未接続の端末からは利用・共有リンクの閲覧ができない。

## バックアップ

バックアップ先は未定のため、別媒体への自動転送は設定していない。
Immich標準のDB dumpは毎日02:00に作成され、直近14個を`/srv/immich/backups`へ保持する。
管理画面の「Administration → Settings」で変更でき、
「Job Queues → Create job → Create Database Dump」から手動作成できる。
これは同じRAID内のDBコピーで、写真・動画の別媒体バックアップにはならない。

以下は別の物理媒体を`/mnt/immich-backup`へマウントした後の手動保存例。
Immichを停止してDBとファイルを同じ時点で取得する。PostgreSQL自体は停止しない。
保存完了までアップロード・閲覧は停止する。シェル終了時にImmichを再開する。

```sh
sudo bash
set -euo pipefail
umask 077
backup_mount=/mnt/immich-backup
mountpoint -q "$backup_mount"
backup_dir="$backup_mount/immich/$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$backup_dir"
trap 'systemctl start immich-server.service immich-machine-learning.service' EXIT
systemctl stop immich-server.service immich-machine-learning.service
runuser -u postgres -- pg_dump --format=custom immich > "$backup_dir/database.dump"
tar --acls --xattrs -C /srv -cpf "$backup_dir/media.tar" immich
git -C /home/jinji/servers-config rev-parse HEAD > "$backup_dir/configuration-revision.txt"
cp /home/jinji/servers-config/flake.lock "$backup_dir/flake.lock"
exit
```

この`database.dump`は手動復旧用のPostgreSQL custom形式であり、
Immich標準の`.sql.gz`とは異なる。保存先には写真・動画を含むため、
媒体のアクセス権限と暗号化を管理する。

## 手動バックアップからの復旧

まずバックアップ時のリポジトリrevision・`flake.lock`を使って環境を用意する。
次は**復旧先のDB・`/srv/immich`をバックアップ内容へ置き換える操作**。
復旧先に残すデータがある場合は先に退避する。
`backup_dir`を実際の保存日時へ変更し、復旧先で実行する。

```sh
sudo bash
set -euo pipefail
backup_dir=/mnt/immich-backup/immich/20261106-120000
test -s "$backup_dir/database.dump"
test -s "$backup_dir/media.tar"
systemctl stop immich-server.service immich-machine-learning.service
systemctl start postgresql.service
runuser -u postgres -- pg_restore --clean --if-exists --single-transaction --exit-on-error \
  --dbname=immich < "$backup_dir/database.dump"
test ! -e /srv/immich.before-restore
mv /srv/immich /srv/immich.before-restore
tar --acls --xattrs -C /srv -xpf "$backup_dir/media.tar"
chown -R immich:immich /srv/immich
systemctl start immich-server.service immich-machine-learning.service
exit
```

復旧に失敗した場合はImmichを停止したまま原因を確認する。
成功後はログイン・写真表示・動画再生を確認する。
復旧前のメディアは`/srv/immich.before-restore`に残るため、確認後に整理する。
元の保存パス`/srv/immich`を維持し、DBとメディアをセットで戻す。
モデルキャッシュは再ダウンロードできるため、この手順では保存しない。

参考: [Immich Backup and Restore](https://docs.immich.app/administration/backup-and-restore/)、
[Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/concepts/)。
