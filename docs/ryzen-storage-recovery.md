# Ryzen SSD・RAID復旧手順

mdadm RAID1 + ext4で稼働するRyzenの、片側SSD脱落・故障からの復旧手順。
正常側で縮退起動できることを前提とする。両側故障や、両側を別々に起動して書き込んだ場合は対象外。
その場合は書き込みを止め、残存データとバックアップから復旧方針を決める。

## 構成とディスクの識別

| 項目 | 値 |
|---|---|
| MDアレイ | `/dev/md/ryzen`（カーネル上の名前は`md127`等） |
| Array UUID | `841f6aa1:604f4db7:a1548902:1d48109f` |
| メタデータ | 1.2、internal write-intent bitmap |
| ルート | ext4、ラベル`RYZEN_ROOT`。`/nix`・`/srv`も同じファイルシステム |
| A側 | ESP `RYZEN_EFI_A` → `/boot`、RAIDパーティション `RYZEN_RAID_A` |
| B側 | ESP `RYZEN_EFI_B` → `/boot-mirror`、RAIDパーティション `RYZEN_RAID_B` |
| 起動方式 | UEFI、各SSDの独立したESPにGRUB・kernel・initrdを配置 |

初期導入時のディスク台帳。交換後はモデル・シリアルを更新する。

| 側 | モデル | シリアル |
|---|---|---|
| A | KIOXIA-EXCERIA PLUS SSD | `Y2MA3026K332` |
| B | NX-512 2280 | `0040141320286` |

`nvme0n1`と`nvme1n1`の対応は再起動で変わる。モデル・シリアルと`by-id`で対象を特定する。
RAID状態の`removed`だけでは、SSDがOSから見えないのか、再参加していないだけなのかは判断できない。

## 1. 状態を確認する

稼働中のRyzenへLANまたはCloudflare Mesh経由でSSH接続し、次を確認する。
Mesh接続例は`ssh jinji@100.96.0.1`（登録変更時はダッシュボードのIPを使用）。

```sh
cat /proc/mdstat
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,PARTLABEL,MOUNTPOINTS
ls -l /dev/disk/by-id/nvme-*
sudo mdadm --detail /dev/md/ryzen
sudo journalctl -k -b --no-pager -g 'nvme|md|raid'
sudo journalctl -u mdmonitor.service -u ryzen-storage-health.service -b --no-pager -n 80
```

- `[UU]`は両メンバー参加、`[U_]`・`[_U]`は片側欠損。復旧完了には同期完了の確認も必要。
- 縮退中は`sudo systemctl start ryzen-storage-health.service`が失敗するのが期待動作。
- SSDが`lsblk`にもない場合は、電源を切って接続・UEFI認識を確認する。繰り返すなら故障として調べる。
- 見えているSSDの健康状態は`sudo smartctl -a /dev/disk/by-id/対象SSDのID`で確認する。

NVMeの抜き差しは完全に電源を切って行う。復旧作業中は最新の書き込みを持つ正常側を維持し、
外していた古い側だけで起動しない。RAIDと両ESPが復旧するまでOS更新・GRUB再配置は行わない。

## 2. 同じSSDを戻す場合

故障のないSSDを一時的に外し、その間は残った側だけを使用した場合の手順。
接続不良で脱落した場合は原因を解消してから行う。実機試験では自動再参加する場合と、
`--re-add`が必要な場合の両方があった。

両台を接続して起動し、セクション1で状態を確認する。
既に両台が参加・再同期中なら追加操作はせず、セクション4へ進む。

Bを戻したが未参加の場合の例（Aなら末尾を`A`に読み替える）:

```sh
sudo mdadm --examine /dev/disk/by-partlabel/RYZEN_RAID_B
```

Array UUIDが上記構成と一致し、外していた元のメンバーであることを確認する。
そのSSD側で独立した書き込みをしていない場合のみ、実行する。

```sh
sudo mdadm --manage /dev/md/ryzen --re-add /dev/disk/by-partlabel/RYZEN_RAID_B
```

デバイスが存在しない、UUIDが違う、コマンドが拒否された場合は、そこで止めて原因を調べる。
`--force`、`--zero-superblock`、フォーマットで押し通さない。
成功したらセクション4で同期完了を確認する。

## 3. 故障SSDを新品へ交換する場合

交換用SSDは、ESP 2GiBに加えて既存アレイのメンバーを収容できる容量が必要。
公称500GB等の表示だけで判断せず、実際のセクター数と`mdadm --examine`の
`Used Dev Size`・`Data Offset`を確認する。初期アレイは約463.63GiBで、別途メタデータ領域を使う。

1. セクション1で故障側のシリアルを特定し、電源を切ってそのSSDだけを交換する。
2. 正常側から縮退起動し、新品のシリアル・`by-id`を確認する。
3. 以下で**新品だけ**を初期化する。既存の故障SSDは接続しない。

以下はBを交換する例。Aを交換するときは`side=A`にする。
必要なツールがない場合は、rootシェルで`nix shell nixpkgs#parted nixpkgs#dosfstools`を使用する。

```bash
sudo -i
set -e
side=B
replacement=/dev/disk/by-id/nvme-新品の実際のID

test -b "$replacement"
case "$side" in A|B) ;; *) exit 1 ;; esac
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$replacement"
mdadm --detail /dev/md/ryzen
```

**ここで、新品のシリアルと一致し、稼働中の正常側ではなく、全データを消去してよいことを確認する。**
次のブロックはその新品のパーティションテーブルを消去する。同じrootシェルで続ける。

```bash
parted -s "$replacement" mklabel gpt \
  mkpart "RYZEN_EFI_${side}" fat32 1MiB 2049MiB set 1 esp on \
  mkpart "RYZEN_RAID_${side}" ext4 2049MiB 100% set 2 raid on
udevadm settle

test "$(readlink -f "${replacement}-part1")" = \
  "$(readlink -f "/dev/disk/by-partlabel/RYZEN_EFI_${side}")"
test "$(readlink -f "${replacement}-part2")" = \
  "$(readlink -f "/dev/disk/by-partlabel/RYZEN_RAID_${side}")"

mkfs.vfat -F32 -n "RYZEN_EFI_${side}" "${replacement}-part1"
udevadm settle
mdadm --manage /dev/md/ryzen --add "${replacement}-part2"
exit
```

RAID用パーティションに`mkfs.ext4`は実行しない。既存アレイに対する`mdadm --create`も不要。
ext4を含む内容は正常側から再構築される。容量不足や使用中のエラーが出た場合は停止し、対象を確認する。

## 4. 再同期とデータを確認する

```sh
watch -n 2 cat /proc/mdstat
```

`[UU]`で、`recovery`・`resync`・`PENDING`の表示がなくなるまで待つ。Ctrl+Cで終了し、次を実行する。

```sh
sudo mdadm --detail --test /dev/md/ryzen
cat /sys/class/block/$(basename "$(readlink -f /dev/md/ryzen)")/md/sync_action
sudo systemctl start ryzen-storage-health.service
sudo systemctl start ryzen-raid-check.service
sudo journalctl -u ryzen-raid-check.service -n 50 --no-pager
```

`sync_action`が`idle`、ヘルスチェックが成功、今回実行したRAID checkが完了して
`mismatch_cnt=0`になったことを確認する。checkには時間がかかる。
サービスが成功でも`Skipping RAID check`なら検査は未実施なので、同期完了後に再実行する。
不一致がある場合はログとバックアップを調べる。`repair`は自動実行しない。

試験時は`cat /srv/degraded-test.txt`で縮退中に書いた日時を確認する。
本番では実際のアプリケーションのデータも確認する。RAIDの健全性だけでは内容の正しさを保証しない。

## 5. 両ESPの起動ファイルを復旧する

新品のESPには起動ファイルがない。RAID再同期とは別にGRUB・kernel・initrdを配置する。
同じSSDを戻した場合も、まず両ESPのマウントと起動ファイルを確認する。

```bash
sudo -i
set -e
mountpoint -q /boot || mount /boot
mountpoint -q /boot-mirror || mount /boot-mirror
findmnt /boot
findmnt /boot-mirror
lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS
```

`/boot`が`RYZEN_EFI_A`、`/boot-mirror`が`RYZEN_EFI_B`のvfatであることを照合する。
新品へ交換した場合、または起動ファイルが欠損している場合は、同じrootシェルで再配置する。
使用する`/etc/nixos`は実機のカーネル・hardware設定を含む復旧対象構成とし、flake.lockを更新しない。

```bash
nixos-rebuild boot --install-bootloader --flake /etc/nixos#ryzen
```

両方のGRUBインストールが成功したことを確認する。同じSSDを戻して再配置を省略した場合も、次は確認する。

```bash
test -s /boot/EFI/BOOT/BOOTX64.EFI
test -s /boot-mirror/EFI/BOOT/BOOTX64.EFI
ls /boot/kernels /boot-mirror/kernels
exit
```

UEFIの起動候補に両SSDの`EFI/BOOT/BOOTX64.EFI`を含める。
再起動後にLAN/Mesh SSH、`[UU]`、ヘルスチェック、データ保持を確認する。
片側起動試験をする場合は、一方向の再参加・再同期を完了してから逆方向へ進む。
新品側だけでも起動できることを確認し、最後は両台を接続して健全な状態へ戻す。

## 起動できない場合・カーネル互換性

2026-09-26の実機導入では、USB側Linux 7.2.7で扱えるアレイを、インストール先6.18.53が
`does not have a valid v1.2 superblock`で拒否し、`RYZEN_ROOT`待ちでタイムアウトした。
インストール先を7.2.7へ変更して正常起動を確認した。構成は`pkgs.linuxPackages_latest`を使用する。
救援USBも、対象アレイを扱えるカーネルを使用し、古い世代へのロールバック時はこの互換性に注意する。

`RYZEN_ROOT`のタイムアウトだけを根拠にアレイを作り直さない。USBで次を採取し、
起動に失敗した側のカーネルログと比較する。USBでは`/dev/md127`等、名前が変わることがある。

```sh
uname -r
mdadm --version
cat /proc/mdstat
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS
sudo mdadm --detail --scan
sudo mdadm --examine /dev/disk/by-partlabel/RYZEN_RAID_A /dev/disk/by-partlabel/RYZEN_RAID_B
```

失敗するinitrdを調べる場合は、GRUBの`e`で`linux`行の末尾へ
`rd.systemd.debug_shell=tty9`を一時追加してCtrl+Xで起動し、Ctrl+Alt+F9でシェルへ移る。
`cat /etc/mdadm.conf`、`cat /proc/mdstat`、`journalctl -k -b --no-pager`を確認する。

## 参照

- [mdadm: --re-add / --add](https://man7.org/linux/man-pages/man8/mdadm.8.html)
- [Linux MD: 管理情報とカーネル互換性](https://docs.kernel.org/admin-guide/md.html)
