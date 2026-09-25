# Phase 1: Ryzen初回インストール

## 確定した方針

- 暗号化なし。NVMe 500GB ×2、mdadm RAID1 + ext4（metadata 1.2、internal bitmap）。
- 片方が故障しても自動で縮退起動を行う。各SSDに独立したESPとGRUB、kernel、initrdを配置する。
- ホスト名`ryzen`、管理ユーザー`jinji`、既存ROCK 3Bと同じSSH公開鍵。
- DHCPを使用し、固定アドレスはルーターのDHCP予約で設定。
- 管理接続はCloudflare MeshとLAN内SSH。SSHは公開鍵認証のみ。
- SSHの接続元はIPv4プライベート範囲・Mesh範囲、IPv6 ULA・link-localに限定。
  ルーターでSSHのポート転送は設定しない。
- SMART、mdadmイベント監視、月次RAID check、5分ごとのRAID状態確認。通知は行わずjournalへ記録。
- Nix GCは日曜04:00、30日より古い世代を削除。journalは最大512MiB・30日。
- `/`を単一のext4とし、`/nix`・`/srv`は通常のディレクトリ。LVM、圧縮、スナップショットは使用しない。
- ディスクswapなし。zramを有効化。

この手順はRyzen実機上で実行する。インストーラーUSB、画面・キーボード、Ethernet、
`jinji`の公開鍵に対応する秘密鍵を持った管理端末を用意する。

## 1. 起動とディスクの確認

NixOS installerをUEFIモードで起動する。Secure Bootは無効にする。
BIOSで両NVMeの認識と、両SSDを対象とする起動順序を確認する。
CPUに内蔵GPUがない構成では、初期設定用のGPUも必要。

```sh
sudo -i
test -d /sys/firmware/efi
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/nvme-*
ip -br link
ip -br address
```

EthernetのMACを控えてルーターでDHCP予約する。
メモリ検査とEthernetの安定性確認はPhase 0として別途実施する。

## 2. パーティション作成

**以下は選択した2台の全データを消去する。** `nvme0n1`のような列挙順ではなく、
モデル・シリアルを照合した`by-id`を指定する。インストーラーUSBを対象にしない。
以下の`実際のID`は実機の値に置き換える。

```bash
disk_a=/dev/disk/by-id/nvme-実際のID_A
disk_b=/dev/disk/by-id/nvme-実際のID_B
test -b "$disk_a" && test -b "$disk_b"
test "$(readlink -f "$disk_a")" != "$(readlink -f "$disk_b")"
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$disk_a" "$disk_b"
```

上記の確認がすべて成功し、両方とも消去対象のディスクであることを確認してから続ける。
必要なコマンドがない場合は、一時的に`nix shell nixpkgs#parted nixpkgs#dosfstools nixpkgs#mdadm nixpkgs#e2fsprogs`を使用する。

```bash
set -e
parted -s "$disk_a" mklabel gpt \
  mkpart RYZEN_EFI_A fat32 1MiB 2049MiB set 1 esp on \
  mkpart RYZEN_RAID_A ext4 2049MiB 100% set 2 raid on
parted -s "$disk_b" mklabel gpt \
  mkpart RYZEN_EFI_B fat32 1MiB 2049MiB set 1 esp on \
  mkpart RYZEN_RAID_B ext4 2049MiB 100% set 2 raid on
udevadm settle

mkfs.vfat -F32 -n RYZEN_EFI_A /dev/disk/by-partlabel/RYZEN_EFI_A
mkfs.vfat -F32 -n RYZEN_EFI_B /dev/disk/by-partlabel/RYZEN_EFI_B
mdadm --create /dev/md/ryzen --metadata=1.2 --level=1 --raid-devices=2 \
  --bitmap=internal --homehost=ryzen --name=root \
  --uuid=841f6aa1:604f4db7:a1548902:1d48109f \
  /dev/disk/by-partlabel/RYZEN_RAID_A /dev/disk/by-partlabel/RYZEN_RAID_B
mkfs.ext4 -L RYZEN_ROOT /dev/md/ryzen
udevadm settle

mount /dev/disk/by-label/RYZEN_ROOT /mnt
mkdir -p /mnt/{nix,srv,boot,boot-mirror}
mount /dev/disk/by-label/RYZEN_EFI_A /mnt/boot
mount /dev/disk/by-label/RYZEN_EFI_B /mnt/boot-mirror
cat /proc/mdstat
mdadm --detail /dev/md/ryzen
```

RAID1の2メンバーであることを確認する。初期同期中でもインストールは進められるが、
再起動・故障試験は同期完了（`/proc/mdstat`が`[UU]`、resync表示なし）を待ってから行う。
ラベルとUUIDは構成と対応しているため変更しない。上記UUIDはこのRyzen用に割り当てた値。
別マシンへの流用時は新しいUUIDを割り当て、`storage.nix`と作成コマンドの両方を変更する。
同じラベル・UUIDの別アレイを接続しない。`--force`や`--assume-clean`は使用しない。

## 3. 構成を配置してインストール

このリポジトリを管理端末から転送するか、Gitから取得し、
`/mnt/etc/nixos`へ配置する（`flake.nix`が直下にある状態）。
未コミットの追加ファイルも含め、今回の変更全体を転送する。

```sh
nixos-generate-config --root /mnt --no-filesystems --show-hardware-config \
  > /mnt/etc/nixos/hosts/ryzen/hardware-configuration.nix
cd /mnt/etc/nixos
git add flake.nix flake.lock hosts modules tests
nix flake check --no-build
nixos-install --root /mnt --flake /mnt/etc/nixos#ryzen --no-root-passwd
nixos-enter --root /mnt -c 'passwd jinji'
```

生成したhardware設定を確認する。ファイルシステムは`storage.nix`で管理し、
自動生成の`configuration.nix`やfilesystem設定を重ねてimportしない。
`passwd jinji`はローカルログインとsudo用。SSHパスワード認証は無効のまま。
rootパスワードは設定しない。

再起動前に両方のESPへの配置を確認する。

```sh
test -s /mnt/boot/EFI/BOOT/BOOTX64.EFI
test -s /mnt/boot-mirror/EFI/BOOT/BOOTX64.EFI
ls /mnt/boot/kernels /mnt/boot-mirror/kernels
```

UEFIが自動認識しない機種では、ファームウェア設定画面で各SSDの
`EFI/BOOT/BOOTX64.EFI`を起動候補として登録する。両SSDを候補に含める。
インストーラーを外して再起動し、LANから`ssh jinji@予約したIP`で接続する。
実機で確定したhardware設定をGitへコミットし、管理端末にも保存する。

## 4. Cloudflare Mesh登録

NixOSはCloudflareの公式Linux対応OS一覧にはないため、NixpkgsのWARPパッケージを使用する。
外部接続と再起動後の再接続は実機で確認する。

1. Cloudflare dashboardの **Networking → Mesh → Add participant → Add node** で`ryzen`を作成する。
2. ノードのdevice profileはMASQUEを使用する。
3. 管理端末のCloudflare One Clientを同じZero Trust組織へ登録する。
4. 管理端末のSplit Tunnel設定でMesh範囲`100.96.0.0/12`をCloudflareへルーティングする。
5. Gatewayのネットワークポリシーで管理端末からRyzenへのTCP 22を許可する。
6. サーバーのLAN範囲はWARPへ取り込まないようSplit Tunnelを確認し、LAN内SSHも試験する。

RyzenのローカルコンソールかLAN内SSHから登録する。ノード自身への到達だけなので、
LAN向けCIDR routeやIP forwardingは追加しない。

```bash
sudo -i
systemctl status cloudflare-warp.service
read -r -s -p 'Mesh node token: ' mesh_token; echo
warp-cli --accept-tos connector new "$mesh_token"
unset mesh_token
warp-cli --accept-tos connect
warp-cli status
exit
```

トークンをファイル・Git・Nix式・コマンド履歴へ直接記入しない。
sudoのコマンドログにトークンを残さないよう、先にrootシェルへ入ってから入力する。
登録時はCLIの引数となるため、信頼できる管理環境で実行する。
登録状態は`/var/lib/cloudflare-warp`に永続化される。
未登録状態ではサービスの起動だけでは接続は成立しない。

dashboardのMesh IPに、外部回線の管理端末から`ssh jinji@Mesh-IP`で接続する。
`warp-cli status`のConnected表示だけで完了とせず、再起動後もSSHできることを確認する。

参照: [Cloudflare Mesh公式手順](https://developers.cloudflare.com/mesh/get-started/)、
[クライアント接続](https://developers.cloudflare.com/mesh/guides/connect-client-devices/)。

## 5. 保守状態と受入確認

```sh
findmnt -t ext4,vfat
cat /proc/mdstat
sudo mdadm --detail --test /dev/md/ryzen
sudo systemctl start ryzen-storage-health.service
sudo journalctl -u ryzen-storage-health.service
sudo journalctl -u smartd.service
systemctl list-timers --all
sudo journalctl -u mdmonitor.service
sudo systemctl start ryzen-raid-check.service
sudo journalctl -u ryzen-raid-check.service
```

- 通常の再起動後、LAN SSHとMesh SSHが成功する。
- RAIDは2台で`[UU]`、再同期が完了し、RAID checkの`mismatch_cnt=0`。
- `smartd`が両NVMeを監視している。必要に応じ`sudo smartctl -a /dev/nvme0`等でも確認。
- `mdmonitor.service`、`ryzen-storage-health.timer`、`ryzen-raid-check.timer`、`fstrim.timer`、`nix-gc.timer`が有効。
- `jinji`はSSH公開鍵で接続でき、sudoを使用できる。root SSHとパスワードSSHは拒否される。
- 構成と実機hardware設定がGitに保存されている。

### 片側故障の試験

重要なデータを置く前に実施する。NVMeを抜き差しするときは完全に電源を切る。

1. 両SSDが健全な状態から電源断し、Bを外してAだけで起動する。
2. 手動で起動先やmountオプションを指定せず、SSHまで到達できることを確認する。
3. `/`がext4でマウントされ、`/nix/store`が読めることを確認する。`/srv`へ試験ファイルを書き、その内容を控える。
4. `sudo systemctl start ryzen-storage-health`が失敗し、journalに縮退が記録されることを確認する。
5. 電源断してBを戻し、両SSDで起動する。以下の再参加手順で同期完了と試験ファイルの内容を確認する。
6. 再起動して健全性とデータ保持を確認してから、Aを外す逆方向の試験を行う。

縮退起動ではmdadmがメンバーを待つため、通常より約30秒長くかかる。
縮退中にもログ等が書き込まれる。外していた古いメンバーを戻すだけで正常復旧したと判断しない。
**A単独とB単独をそれぞれ更新した後に、その2台をそのまま再接続しない。**
mdadmも分岐した内容を統合する仕組みではない。以後の起動・復旧では、最新の書き込みを持つ側を維持する。

### 外していたメンバーの再参加

故障のないBを一時的に外し、その間はAだけを使用した場合の例。
両SSDを接続して起動後、`cat /proc/mdstat`と`sudo mdadm --detail /dev/md/ryzen`で状態を確認する。
既にBが再参加・再同期中なら完了を待つ。Bが参加していない場合のみ、以下を実行する。

```sh
sudo mdadm --manage /dev/md/ryzen --re-add /dev/disk/by-partlabel/RYZEN_RAID_B
watch cat /proc/mdstat
```

`[UU]`かつ再同期表示なしになったらwatchを終了する。
`--re-add`が拒否された場合は、`--force`で進めず、メンバーの履歴・故障状態を確認する。
`sudo systemctl start ryzen-storage-health.service ryzen-raid-check.service`が成功し、
試験ファイルの内容が保たれていることを確認して再起動する。
逆方向ではA/Bを読み替える。両側に独立した書き込みがある場合は、この手順の対象外。

物理故障で新品へ交換する場合は、交換側だけに同じパーティション構成・ラベルを作り、
ESPをFAT32で初期化したうえで、新しいRAIDパーティションを`mdadm --manage /dev/md/ryzen --add`へ渡す。
稼働中のアレイに`--create`や`mkfs.ext4`を実行しない。再同期完了後、交換したESPをマウントしてGRUBを再配置する。

縮退中はNixOSの更新・bootloader再インストールを行わない。
GRUBの更新先には両ESPが必要。交換・再同期が完了して両ESPをマウントした後に、
`sudo nixos-rebuild boot --install-bootloader --flake /etc/nixos#ryzen`で両方を更新する。
片側欠損の状態での既存世代の起動は許可するが、更新処理の片側スキップは実装しない。

月次checkはミラー間の不一致を検出し、異常をjournalへ記録する。`repair`は自動実行しない。
不一致があっても、RAID1だけではどちらが正しいかは判断できないため、ログとバックアップを確認する。

参照: [Linux MD](https://docs.kernel.org/admin-guide/md.html)。
UEFIのディスク切替挙動は機種に依存するため、VMテストに加えて両方向の実機試験を完了条件とする。
