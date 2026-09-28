# Nix Remote Builder（Phase 2）

通常はノートPCからMesh上のRyzen（`100.96.0.1` aka `ryzen.home.arpa`）へビルドを委譲する。
flake評価と成果物取得はノートPC側で行う。Ryzenへ接続できない場合は失敗し、自動でローカル実行へは切り替えない。

## 設定と鍵

- サーバー: `modules/system/nix-builder.nix`、`hosts/ryzen/nix-builder.pub`
- クライアント: `~/nixos-config/hosts/laptop/nix-builder.nix`
- 秘密鍵: `~/nixos-config/secrets/nix-builder.yaml`（既存age recipientで暗号化）
- 配備先: `/run/secrets/nix_builder_private_key`（root、0400）

専用鍵は`nix-daemon --stdio`のみ実行でき、PTYやポート転送は許可しない。
ただし`nix-builder`はNixのtrusted userであり、信頼できない利用者向けの隔離には使わない。
ホスト公開鍵は既存のknown_hostsと照合したMesh接続から取得し、クライアントのシステムknown_hostsへ固定する。
Mesh IPやホスト鍵を変更した場合は、クライアント設定も更新する。

Ryzenの初期値は同時1ジョブ・8コア。`big-parallel`を追加し、実機の`/dev/kvm`も確認済み。
この値はメモリ使用量を制限するものではない。

## 適用順序

実機への適用を行う際は、先にRyzen、後からノートPCへ適用する。
Ryzenで専用ユーザーが利用可能になる前にノートPCを切り替えると、新規ビルドを委譲できない。
両リポジトリの新規ファイルをGitで追跡し、Ryzenへは更新したservers-configを転送してから適用する。

Ryzen上:

```sh
sudo nixos-rebuild switch --flake /home/jinji/servers-config#ryzen
```

ノートPC上（既存builder設定に依存せず構築する）:

```sh
sudo nixos-rebuild switch --flake /home/jinji/nixos-config#nixos --builders '' --max-jobs 1
```

## 接続とビルドの確認

適用後、ノートPCでrootから非対話接続できることを確認する。専用鍵で通常のシェルにはログインしない。

```sh
sudo nix store info --store 'ssh-ng://nix-builder@ryzen.home.arpa?ssh-key=/run/secrets/nix_builder_private_key'
```

servers-configで、キャッシュ取得だけでは終了しない小規模ビルドを実行する。

```sh
nix build --impure --no-link --expr '
  let
    flake = builtins.getFlake (toString ./.);
    pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  in pkgs.runCommand "phase2-probe-${toString builtins.currentTime}" {
    preferLocalBuild = false;
    allowSubstitutes = false;
  } "echo ok > $out"
'
```

ログの`building ... on 'ssh-ng://nix-builder@ryzen.home.arpa'`を確認する。
大規模パッケージでは対象の実ビルドとRyzenのメモリ使用量を確認する。
キャッシュ取得のみで終わった試行は、リモートビルドの確認として数えない。
NixOS構成は次のコマンドでビルドし、適用とは分けて確認する。

```sh
nix build .#nixosConfigurations.ryzen.config.system.build.toplevel --no-link
nix build /home/jinji/nixos-config#nixosConfigurations.nixos.config.system.build.toplevel --no-link
```

## 手動でローカルへ切り替える

```sh
nix build --builders '' --max-jobs 1 <installable>
```

ビルド途中で接続が切れた場合も、失敗後にこの指定で再実行する。
途中状態の引き継ぎは保証しない。復旧後は上書き指定を外すだけでRyzenへ戻る。
SSHは接続待ち10秒、応答監視15秒間隔・3回失敗を設定するが、Nixの再試行もあるためコマンド全体の終了時間は別途実測する。

## 検証範囲

`nix flake check`の`nix-builder`試験は、使い捨てVMで専用ユーザー・制限付きSSH鍵によるリモートビルド、接続不能時の失敗、手動ローカル実行、復旧後の再委譲を確認する。
テスト鍵はnixpkgsの公開テスト用鍵で、実運用の秘密鍵はVMへ渡さない。

実機への適用後に、専用鍵の配備、Mesh経由の実ビルド、大規模ビルドのメモリ使用量、途中切断後の再実行を確認してPhase 2を完了とする。

### 実機確認記録（2026-09-27）

- Ryzenへ設定を適用し、`nix-builder`ユーザー、同時1ジョブ・8コア、SSH・Nix daemon・Meshの稼働を確認した。RAIDも`[UU]`を維持している。
- 暗号化した専用鍵を一時的に復号し、固定したホスト鍵を検証してMesh経由の`nix store info`が成功した。試験後に一時鍵は削除した。
- `--max-jobs 0`とコマンド単位の`--builders`指定で、キャッシュを使わない小規模derivationをRyzenでビルドした。クライアントへ戻った成果物の内容も確認した。
- ノートPC側の恒久設定の適用、大規模ビルドのメモリ計測、実機での途中切断試験は未実施。
