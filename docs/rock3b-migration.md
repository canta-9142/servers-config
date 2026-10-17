# ROCK 3B基本構成の移行

`~/nixos-config/hosts/rock3b`から基本構成のみ移植した。
flakeの構成名とホスト名はともに`rock3b`。
この追加だけでは実機の設定や稼働サービスは変わらない。

## 引き継ぐ設定

- aarch64、extlinux、Device Tree、NVMe、既存のルートFS UUIDと4 GiBのswap。
- カーネル選択、PWMファン制御、Ethernet PHY・LED設定、HDMI用EDID、fstrim。
- NetworkManagerによる`end0`優先・`end1`待機のactive-backup bondとDHCP。
- 管理ユーザー`jinji`、fish、CLI、Lixと`NH_PRESERVE_ENV=0`を設定する`nh`ラッパー。
- `nixos-rebuild`に限定した既存のパスワード不要sudoルール。
- `system.stateVersion = "26.05"`。

固定中のnixpkgsでは`phytool`の未使用変数警告がビルドエラーになるため、
ROCKの同パッケージだけ当該警告のエラー扱いを解除している。
パッケージ側で修正されたらこのoverrideは削除できる。

ユーザーとSSHは本リポジトリの共通モジュールを利用する。
管理SSHは鍵認証のみで、共通モジュールのLAN・Meshアドレス範囲から接続を許可する。
ROCK自体にはCloudflare Meshを追加しないため、Tunnel経由のSSHは引き継がれない。
rootのSSHログインは無効。旧`nixos`ユーザーの宣言とFirefoxは引き継がない。

`NH_FLAKE`は`/home/jinji/servers-config#rock3b`、
`/etc/nixos`の参照先は`/home/jinji/servers-config`とする。
適用時には実機の同パスに本リポジトリが必要。

## 引き継がない設定

Forgejo、Actions Runner、Podman、nginx、cloudflared、サーバー用保守設定、
サービス用ドメイン定義と認証情報は含めない。
既存のサービスデータのコピー・削除も行わない。

ロードマップのPhase 8にある待機Webサーバー化は今回の移行に含めない。
基本構成の移植だけではPhase 8全体の完了を意味しない。
移行元の`~/nixos-config`は、実機移行が完了するまでは残す。

## 適用を伴わない検証

```sh
nix develop
nix fmt
statix check .
deadnix --fail .
nix flake check
nix eval --raw .#nixosConfigurations.rock3b.config.system.build.toplevel.drvPath
nix build --no-link .#nixosConfigurations.rock3b.config.system.build.toplevel
```

ROCKの実ビルドにはaarch64の実行環境、binfmtエミュレーション、
または対応するリモートビルダーが必要。
既定のリモートビルダーがx86_64専用で`max-jobs = 0`の場合は、
binfmtが有効なホストでローカルビルドを明示する。

```sh
nix build --builders '' --max-jobs 2 --cores 2 --no-link .#nixosConfigurations.rock3b.config.system.build.toplevel
```

設定の評価だけでは実機の起動、温度制御、bondの切替動作は確認できない。

## NVMe用イメージ

ROCK本体にはU-Bootが設定済みで、NVMe上のextlinuxを読み込めることを前提とする。
`rock3b-image`はMBRと単一のext4パーティションを持つrawイメージを生成する。
U-Boot本体は含めず、`/boot/extlinux/extlinux.conf`、カーネル、initrd、Device Tree、
Nixストアと初期化済みDB・systemプロファイルを含める。
ルートFSのUUIDは既存構成と同じ値にする。

```sh
nix build .#rock3b-image --out-link result-rock3b-image
```

生成物は`result-rock3b-image/rock3b-nvme.img`。
組み立てはx86_64上で行い、実際に起動するシステムはaarch64のまま。
aarch64の依存パッケージを用意するには前述のビルド環境が必要。
ローカルのbinfmtを使用する場合:

```sh
nix build --builders '' --max-jobs 2 --cores 2 .#rock3b-image --out-link result-rock3b-image
```

イメージには4 GiBのswapファイルを初回起動時に作成できるよう5 GiBの余白を持たせる。
起動時にはルートパーティションとext4をNVMeの容量まで拡張する。
ビルド時にMBR、UUID、extlinuxの参照先、NixのDB・systemプロファイルを検査する。

新規イメージにユーザーパスワードや秘密鍵は含めない。SSHには共通設定の公開鍵を使う。
`servers-config`の作業コピーは含めないため、起動後に`/home/jinji/servers-config`へ配置する。
実NVMeへの書き込みや実機での起動確認はイメージ生成とは別作業。
