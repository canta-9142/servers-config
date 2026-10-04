# Nix Binary Cache運用計画（Phase 7）

2026-10-04時点の方針。Binary Cache、定期更新ジョブ、`nixos-config`の正本移行は未実施。
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

Cache serverの選定、実行時刻、ブランチ構成、ジョブの認証・権限、retentionの
具体的な期間は実装時に決める。
