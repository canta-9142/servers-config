# 自宅サーバー構成 要件定義・実装ロードマップ

## 1. 目的

本プロジェクトは、Ryzen搭載PCを主系サーバー、Radxa ROCK 3Bを非常用待機サーバーとして構成し、以下のサービスを安定して提供することを目的とする。

1. Webサーバー
2. Forgejo
3. Forgejo Actions Runner
4. Nix Remote Build Environment
5. Nix Binary Cache

平常時はRyzen機のみで完結させ、ROCK 3Bを常時通信経路へ介在させない。(ROCK 3Bは平常時の停止確率が高いため)

ROCK 3BはUPS配下で常時稼働し、Ryzen機の停止時にWeb公開のみを継続する非常用待機系として利用する。

また、Ryzen機はNixのリモートビルドだけでなく、Linuxカーネルへのパッチ適用・検証時の高速ビルド環境としても利用する。

---

## 2. 基本方針

### 2.1 構成ファイルについて

現在のlaptop及びROCK 3Bのconfigurationファイルは`~/nixos-config`内に存在する。

今後の方針としては、`~/nixos-config`はクライアントのNixOS用、当ディレクトリ`~/servers-config`はサーバーのNixOS用に利用するものとし、最終的にはROCK 3Bのファイルも再構成と同時に`~/servers-config`へ移動する。

また`~/servers-config`についても`~/nixos-config`と同じようなファイルパターンで構成する。

### 2.2 主系と待機系

- Ryzen機を唯一の主系サーバーとする。
- ROCK 3Bは非常用Webサーバーとして待機させる。
- 平常時のWeb、Git、CI、Nix関連処理はすべてRyzen機で行う。
- ROCK 3Bは平常時のリクエスト経路には入れない。
- 障害時のみWebトラフィックをROCK 3Bへ切り替える。

### 2.3 保存するデータの正

以下を正とする。

- Gitリポジトリ: Ryzen上のForgejo
- Gitバックアップ: Forgejoのミラー機能によるGitHub
- Webソース: Forgejo
- Web公開成果物: Forgejo Actions Runnerによって生成されたCI成果物
- Nix build result: Ryzen上のNix StoreおよびBinary Cache

ROCK 3BにはGitリポジトリのバックアップを保持しない。

### 2.4 障害モデル

以下の障害状態を想定する。

#### 通常状態

- Ryzen: 稼働
- ROCK 3B: 稼働
- ルーター/ONU: 稼働

すべてのサービスをRyzenが提供する。

#### Ryzenのみ停止

例:

- 停電によりRyzen停止
- RyzenのOS障害
- Ryzenのカーネルパニック
- Ryzenのネットワーク障害
- nginx / cloudflared障害

この場合:

- WebのみROCK 3Bへフェイルオーバーする。
- Forgejoは利用不能とする。
- Actions Runnerは利用不能とする。
- Nix Remote Builderは利用不能とする。
- Nixクライアントは手動指定でローカルビルドへ切り替える。
- Nix Binary Cacheは利用不能でも許容する。

#### ROCK 3Bのみ停止

通常時のサービス提供には影響を与えない。

#### RyzenとROCK 3Bの両方が停止

ルーター故障、ONU故障、UPS系統障害、Cloudflareの障害などを含む。

この状態は非常に稀かつ家庭内設備のみでは対処不能な障害として扱い、追加の冗長化対策は行わない。

---

## 3. ハードウェア構成

## 3.1 Ryzenサーバー

想定構成:

- CPU: AMD Ryzen 7 3700X
- RAM: 16GB (年内までに32GBへアップグレード予定)
- NVMe SSD: 500GB × 2, mdadm RAID1 + ext4
- OS: NixOS
- ネットワーク: 有線Ethernet

主用途:

- Webサーバー
- Forgejo
- Forgejo Actions Runner
- Nix Remote Builder
- Nix Binary Cache
- Linux kernel build
- CI/CD

### ストレージ

500GB NVMe SSD 2枚をミラー構成で使用する。

採用構成:

- Linux MD（mdadm）RAID1 + ext4
- usable capacity: 約500GB
- RAID metadata 1.2、internal write-intent bitmapを使用
- 定期的なRAID整合性チェック（check）と結果のログ記録
- SMART監視
- 定期的なclean up

RAIDメンバー管理と再同期はmdadmに任せ、ext4は単一のMDデバイス上に作成する。
`/nix`と`/srv`は同じext4内の通常のディレクトリとし、LVMや容量の固定分割は追加しない。
ファイルシステムのスナップショットと透過圧縮は使用しない。

片方のSSDが欠損した場合も、残ったメンバーから自動で縮退起動する。
起動時に`--force`で不整合メンバーを強制採用する構成にはしない。
再参加・交換時は同期状態を確認し、再同期完了をもって冗長性の復旧とする。
両メンバーを独立して更新した場合の自動統合は保証しない。

各SSDに独立したFAT32のEFI System Partition（ESP）を配置し、両方から起動可能にする。
ESPはMD RAIDに含めず、GRUBの`mirroredBoots`でOS更新時に両方の起動ファイルを更新する。
縮退中のOS・bootloader更新は行わず、両ESPとRAIDの復旧後に実施する。

想定領域:

```text
/
├── /nix
├── /srv/forgejo
├── /srv/www
├── /srv/kernel
└── /srv/nix-cache
```

kernel build treeやccacheもext4上に配置する。

---

## 3.2 ROCK 3B

ROCK 3Bは非常用待機サーバーとして再構築する。

搭載する主なサービス:

- NixOS
- nginx
- cloudflared
- OpenSSH
- Web公開成果物

原則として搭載しないもの:

- Forgejo
- Forgejo Actions Runner
- Nix Binary Cache
- 重いコンテナ環境
- デスクトップ環境
- Gitバックアップ

ROCK 3B、ルーター、ONUはUPS経由で給電される。

---

## 4. ネットワーク・公開構成

外部との通信はCloudflareを経由することを基本とする。ただし、HTTP公開サービスと管理・ビルド用途の通信では性質が異なるため、以下の2系統に分離する。

* **公開系**: Cloudflare Tunnel / Access
* **管理・ビルド系**: Cloudflare Mesh / Cloudflare One Client

ROCK 3Bを平常時の通信経路やゲートウェイとして使用せず、RyzenとROCK 3Bはそれぞれ独立してCloudflareへ接続する。

### 4.1 公開HTTPサービス

以下のサービスはCloudflare Tunnelを介して公開する。

* Webサーバー
* Forgejo Web UI
* Nix Binary Cache

```mermaid
flowchart LR
    Client["Browser / Nix Client"]
    CF["Cloudflare<br>HTTP / Access"]
    Tunnel["cloudflared<br>Ryzen"]
    Web["nginx"]
    Forgejo["Forgejo"]
    Cache["Nix Binary Cache"]

    Client --> CF
    CF --> Tunnel
    Tunnel --> Web
    Tunnel --> Forgejo
    Tunnel --> Cache
```

平常時はRyzen側のTunnelのみを主系として使用する。

ROCK 3Bは非常用Webサーバー専用のTunnelを持ち、通常時の通信経路には介在させない。

### 4.2 Webフェイルオーバー

Webサーバーの冗長化には、Cloudflare Load BalancingによるActive-Passive Failoverを使用する。

RyzenとROCK 3Bにはそれぞれ独立したCloudflare Tunnelを構築し、同一Tunnelのreplicaとしては構成しない。

```mermaid
flowchart TD
    Client["Client"]
    CF["Cloudflare"]
    LB["Cloudflare Load Balancer<br>Off - Failover"]

    Primary["Primary Pool"]
    Standby["Standby Pool"]

    RT["Ryzen Tunnel<br>UUID A"]
    BT["ROCK Tunnel<br>UUID B"]

    RN["Ryzen nginx"]
    BN["ROCK nginx"]

    Client --> CF --> LB

    LB -->|"通常時"| Primary
    LB -.->|"Primary unhealthy"| Standby

    Primary --> RT --> RN
    Standby --> BT --> BN
```

#### Tunnel構成

以下の2本のTunnelを独立して作成する。

```text
web-ryzen
└── Ryzen nginx

web-rock
└── ROCK 3B nginx
```

それぞれ異なるTunnel UUIDを持たせる。

同一Tunnel UUIDをRyzenとROCKで共有する構成は採用しない。

これは、同一TunnelのreplicaではCloudflare Load Balancerから個別のoriginとして識別できず、RyzenとROCK間で明示的な優先順位を設定できないためである。

#### Load Balancer構成

Web公開hostnameにCloudflare Public Load Balancerを設定する。

Load Balancerには以下の2つのpoolを設定する。

| Pool          | Endpoint          | 役割                 |
| ------------- | ----------------- | ------------------ |
| `web-primary` | Ryzen Tunnel UUID | Primary            |
| `web-standby` | ROCK Tunnel UUID  | Standby / Fallback |

Tunnel endpointには以下の形式を使用する。

```text
<RYZEN_TUNNEL_UUID>.cfargotunnel.com
<ROCK_TUNNEL_UUID>.cfargotunnel.com
```

各endpointにはWeb公開hostnameをHost headerとして設定する。

Traffic Steeringは `Off - Failover` とし、poolの優先順位を以下とする。

```text
1. web-primary
2. web-standby
```

Fallback Poolには`web-standby`を指定する。

これにより通常時はRyzenのみへトラフィックを送り、Ryzen側poolがunhealthyと判定された場合のみROCK 3Bへ切り替える。

Ryzen側が再びhealthyになった場合は、自動的にRyzenへfailbackする。

---

#### Health Check

障害判定にはCloudflare Load BalancerのHTTPS Monitorを使用する。

単に`cloudflared`プロセスがCloudflareへ接続できることだけではなく、nginxまで正常に応答できることを確認する。

両サーバーのnginxに以下のhealth check endpointを用意する。

```text
/healthz
```

正常時には以下を返す。

```text
HTTP 200
Body: ok
```

Health Monitorは概ね以下の条件とする。

```text
Protocol: HTTPS
Method: GET
Path: /healthz
Expected Status: 200
Expected Body: ok
Host Header: Web公開hostname
```

Cloudflare Load BalancingのMonitorはHTTP status codeだけでなくresponse bodyも検証可能なため、単純なTCP接続確認よりもアプリケーションに近いレベルで正常性を判断する。

必要に応じてMonitor専用HTTP headerを追加する。

例:

```text
X-Health-Check: <secret>
```

nginx側では、このheaderを持つHealth Monitorからのリクエストにのみ`/healthz`を応答させる構成としてもよい。

Webサイト自体をCloudflare Accessで保護する場合は、Health MonitorがAccess認証によって遮断されないよう、`/healthz`のみ別途Monitor用の経路を設ける。

---

#### 障害判定

以下のいずれかにより`/healthz`への正常な応答が失われた場合、Ryzen側をunhealthyと判断する。

```text
Ryzen電源断
Ryzen OS停止 / kernel panic
ネットワーク断
cloudflared停止
nginx停止
nginx設定異常
Web公開経路の異常
```

これにより、単にTunnel connectionが存在するだけでWebサービスをhealthyとはみなさない。

Health Monitorのinterval、timeout、retry、`consecutive_down`、`consecutive_up`は誤検知と切替時間のバランスを考慮して設定する。

初期設定では、単発のpacket loss等でfailoverしないよう、複数回連続で失敗した場合にunhealthyとする。

```text
Healthy
  ↓
Health Check Failure
  ↓
再試行 / 連続失敗確認
  ↓
Primary Unhealthy
  ↓
ROCKへFailover
```

復旧時も同様に複数回の正常応答を確認してからRyzenをhealthyへ戻し、短時間の状態変化による頻繁な切り替えを防止する。

---

#### フェイルオーバー時の動作

通常時:

```text
Client
  ↓
Cloudflare
  ↓
web-primary
  ↓
Ryzen Tunnel
  ↓
Ryzen nginx
```

Ryzen障害時:

```text
Client
  ↓
Cloudflare
  ↓
web-standby
  ↓
ROCK Tunnel
  ↓
ROCK nginx
```

Ryzen復旧時:

```text
Ryzen /healthz recovery
  ↓
Cloudflare Monitor detects healthy
  ↓
web-primary healthy
  ↓
automatic failback
  ↓
Ryzen nginx
```

ROCK 3Bは平常時の通信経路には介在しない。

---

#### Webコンテンツの整合性

ROCK側には、Forgejo Actions RunnerによってRyzenと同時にデプロイされた最後の正常releaseを保持する。

```mermaid
flowchart LR
    Runner["Actions Runner"]
    Artifact["Web Artifact<br>release = commit hash"]

    Ryzen["Ryzen"]
    Rock["ROCK"]

    Runner --> Artifact
    Artifact --> Ryzen
    Artifact --> Rock
```

フェイルオーバー機構はWebコンテンツの同期を行わない。

コンテンツ同期はCI/CDの責務とし、Cloudflare Load Balancerは既にデプロイ済みのorigin間で通信先を切り替えることだけを担当する。

---

#### 両系統障害時

RyzenとROCKの両方がunhealthyになった場合、正常なWeb提供は保証しない。

Cloudflare Load Balancerではすべてのpoolがunhealthyの場合でもFallback Poolが最終的な転送先となるため、`web-standby`をFallback Poolとして設定する。

ただしROCK自身も停止している場合、Webアクセス不能となることを許容する。

これは以下のような状況を想定する。

```text
UPS停止
ルーター故障
ONU故障
回線障害
RyzenとROCKの同時故障
```

これらは本システムの冗長化対象外とする。

---

#### 障害試験

構築後、以下の障害を意図的に発生させてfailoverを確認する。

```text
1. Ryzen nginx停止
2. Ryzen cloudflared停止
3. Ryzen Ethernet切断
4. Ryzen shutdown
5. Ryzen再起動・復旧
```

各試験について以下を確認する。

```text
Primaryがunhealthyになる
        ↓
ROCKへ切り替わる
        ↓
Webが閲覧可能
        ↓
Ryzen復旧
        ↓
Primaryがhealthyになる
        ↓
Ryzenへ自動failback
```

また、ROCK停止中でもRyzenの通常運用に一切影響しないことを確認する。

---

#### 実装上の前提

Cloudflare Load BalancingはCloudflare Tunnelとは別のadd-on機能として使用する。

2026年9月時点でCloudflareのBasic Load Balancingは月額課金のadd-onとして提供されている。

この追加費用は、ROCKを常時proxyとして経由させずに、Cloudflare側でhealth check、failover、failbackを完結させるための運用コストとして許容する。


### 4.3 管理・ビルドネットワーク

SSH、Nix Remote Build、ホスト間管理通信などはCloudflareのHTTPプロキシを使用せず、Cloudflare Meshを使用する。

各管理対象ホストを独立したMesh nodeとして接続する。

```mermaid
flowchart LR
    Laptop["Laptop<br>Cloudflare One Client"]
    Mesh["Cloudflare Mesh"]

    Ryzen["Ryzen<br>Mesh Node"]
    Rock["ROCK 3B<br>Mesh Node"]

    Laptop <--> Mesh
    Mesh <--> Ryzen
    Mesh <--> Rock
```

主な用途:

* RyzenへのSSH
* ROCK 3BへのSSH
* Nix Remote Build
* 管理用ファイル転送
* ホスト間の管理通信

これにより、Cloudflare HTTP proxyのリクエストサイズ制限や、`cloudflared access ssh`によるWebSocket接続への依存を避ける。

Nix Remote BuildはMesh上の通常のSSH接続として構成する。

```mermaid
flowchart LR
    Laptop["NixOS Client"]
    Mesh["Cloudflare Mesh"]
    Ryzen["Ryzen<br>sshd + nix-daemon"]

    Laptop -->|"SSH"| Mesh
    Mesh --> Ryzen
```

Ryzenが利用不能な場合、NixクライアントはROCK 3Bへ切り替えず、手動指定でローカルビルドへ切り替える。

### 4.4 Git通信

ForgejoのWeb UIはCloudflare Tunnel経由で公開する。

Git操作については、大容量push時にCloudflareのHTTP request size制限の影響を受ける可能性があるため、SSHを基本とする。

```mermaid
flowchart LR
    Laptop["Developer PC"]
    Mesh["Cloudflare Mesh"]
    Forgejo["Ryzen<br>Forgejo SSH"]

    Laptop -->|"Git over SSH"| Mesh
    Mesh --> Forgejo
```

GitHubへのバックアップミラーはForgejoから直接実行する。

Git LFS等の大容量HTTPアップロードについては、必要になった時点で別途転送経路を検討する。

### 4.5 Nix Binary Cache

Binary Cacheの読み出しはCloudflare Tunnel経由のHTTPで提供する。

```mermaid
flowchart LR
    Client["Nix Client"]
    CF["Cloudflare HTTP"]
    Cache["Ryzen<br>Nix Binary Cache"]

    Client -->|"GET"| CF
    CF --> Cache
```

Binary Cacheへの書き込みは原則としてRyzen上のCIまたはローカルネットワーク内部から行い、Cloudflare HTTP経由で外部からuploadしない。

これにより、Cloudflare HTTP request bodyのサイズ制限の影響を避ける。

### 4.6 通信経路の役割分担

| 通信                 | 経路                         |
| ------------------ | -------------------------- |
| Web閲覧              | Cloudflare Tunnel          |
| Forgejo Web UI     | Cloudflare Tunnel / Access |
| Nix Binary Cache取得 | Cloudflare Tunnel          |
| Git push / pull    | Cloudflare Mesh + SSH      |
| Ryzen管理SSH         | Cloudflare Mesh            |
| ROCK管理SSH          | Cloudflare Mesh            |
| Nix Remote Build   | Cloudflare Mesh + SSH      |
| Web failover       | Cloudflare側でRyzen → ROCK切替 |

この構成により、公開サービスと管理ネットワークを分離しつつ、RyzenとROCK 3Bの間に不要な依存関係を作らない。

平常時はRyzenのみで主要サービスが完結し、ROCK 3Bの障害は通常運用へ影響しない構成とする。

---

## 5. Webサーバー要件

### 5.1 平常時

Ryzen上のnginxからWebコンテンツを配信する。

### 5.2 非常時

Ryzenが利用不能になった場合、Cloudflare側でROCK 3Bへ切り替える。

ROCK 3Bは最後に正常デプロイされたWeb成果物を保持する。

### 5.3 デプロイ方式

WebはForgejo Actions Runner上で一度だけビルドする。

同一成果物を以下へデプロイする。

- Ryzen
- ROCK 3B

```mermaid
flowchart LR
    Git["Forgejo"]
    Runner["Forgejo Actions Runner"]
    Build["Build"]
    Ryzen["Ryzen /srv/www"]
    Rock["ROCK /srv/www"]

    Git --> Runner
    Runner --> Build
    Build --> Ryzen
    Build --> Rock
```

RyzenとROCKで別々にbuildしない。

ROCK停止中にROCKへのデプロイが失敗しても、その失敗は許容し、Ryzenへのデプロイと後続処理は継続する。
ROCK復帰後も、明示的な命令がない限り自動同期は行わず、最後に正常デプロイされたWeb成果物を保持する。

### 5.4 リリース管理

`~/nixos-config`に存在するROCK 3B向け構成にすでに運用しているものがあるため、原則それに従う。(モジュールをそのまま持ってくる形が望ましい)

---

## 6. Forgejo要件

ForgejoはRyzen上のみで稼働させる。

役割:

- Gitホスティング
- Actions起点
- Webソース管理
- Nix configuration管理

GitリポジトリはForgejoのミラー機能を使用してGitHubへバックアップする。

ROCK 3BへのGitバックアップは行わない。

Ryzen障害時にForgejoを利用できないことは許容する。

ForgejoのDBや設定など、GitHub mirrorでは保護されないデータについては別途バックアップ手段を用意するかもしれない(現時点では未定)。

---

## 7. Forgejo Actions Runner要件

RunnerもRyzen上で稼働する。

主な用途:

- Web build
- Web deploy
- Nix build
- NixOS configuration build
- Binary Cacheへの成果物登録

Web buildは一度だけ行い、同一artifactをRyzenとROCKの双方へ配布する。

Runner停止時も既存のWeb配信は継続可能であること。

---

## 8. Nix Remote Build Environment

Ryzenをx86_64-linux用のNix Remote Builderとして利用する。

クライアント例:

- メインノートPC
- その他NixOS x86_64マシン

構成:

```mermaid
flowchart LR
    Laptop["NixOS Client"]
    Ryzen["Ryzen Remote Builder"]
    Result["Build Result"]

    Laptop --> Ryzen
    Ryzen --> Result
    Result --> Laptop
```

### 8.1 通常時の実行方針

通常のビルドは原則としてRyzenへ全委譲する。
クライアントの`nix.settings.max-jobs = 0`とし、ローカルとの並列分散は行わない。
flakeの評価、成果物の取得、およびNixがローカル実行を必要とする処理までRyzenへ移すことは要件に含めない。
既存のBinary Cacheから取得できる成果物は通常どおり利用する。

クライアント側（`~/nixos-config`）:

- `nix.distributedBuilds = true`
- `nix.buildMachines`でRyzenを登録し、`ssh-ng`で接続する。
- `nix.settings.builders-use-substitutes = true`として、Ryzenが依存成果物を自身で取得する。
- 接続先はCloudflare Mesh上のRyzenに一本化し、LANへの自動切替は追加しない。
- 対象は`x86_64-linux`とする。

Ryzen側（`~/servers-config`）:

- SSH接続用の専用ユーザー`nix-builder`を作成し、SSHの許可ユーザーに追加する。
- `nix-builder`をNixの`trusted-users`へ登録する。専用ユーザーはNixに対する低権限の隔離境界とはみなさない。
- `big-parallel`を有効化し、`kvm`は実機で利用可能と確認した場合に宣言する。
- 16GB RAMでの初期値は、クライアントの`buildMachines`の`maxJobs = 1`、Ryzenの`max-jobs = 1`、`cores = 8`とする。
- 並列度は大規模ビルドの実測で調整する。これらはメモリ使用量の上限を保証する設定ではない。
- Runnerやカーネル開発とのリソース競合は、それぞれの導入時に再検討する。

### 8.2 SSH鍵の管理

- 管理用SSH鍵とは別に、クライアント専用のビルド用鍵を用意する。
- 秘密鍵はクライアントの既存sops-nixで管理し、Nix daemon（root）が非対話で利用できる権限で配備する。
- 平文の秘密鍵をGitやNix Storeへ格納しない。
- Ryzenには公開鍵のみ登録し、クライアントには信頼できる経路で確認したRyzenのSSHホスト公開鍵を固定する。

### 8.3 Ryzen停止時の動作

- 自動でローカル実行へ切り替える仕組みはPhase 2では導入しない。
- 開始時に接続できない場合も、ビルド途中で切断した場合も、実行の失敗を許容する。
- 利用者が次のようにコマンド単位でローカル実行を指定して再実行する。

```sh
nix build --builders '' --max-jobs 1 <installable>
```

- 切替のためのNixOS設定変更や再適用は不要とする。
- ビルド途中の処理状態の引き継ぎは保証しない。
- ROCK 3Bをx86_64 buildの代替として使用しない。
- Ryzen復旧後は、上記の上書き指定を外した通常のコマンドで再びRyzenへ委譲する。

---

## 9. Nix Binary Cache

Binary CacheはRyzen上で提供する。

運用方針の詳細は[Binary Cache運用計画](docs/nix-binary-cache.md)を参照。
`~/nixos-config`の正本はRyzenのForgejoへ移行済み。
Ryzenで12時間ごとにflake inputsを更新してlaptop構成全体をビルドする計画とする。
システムのclosureをキャッシュへ公開した後、成功した更新コミットだけをpushする。
laptopはCI成功を確認してpullし、原則`--update`なしで`nh os switch`する。
設定変更のmainへのpushでもCIでビルド・公開する。
キャッシュ基盤は実機確認済み、push時CIは設定実装済みで実機実行待ち。
push時CIの初回成功とlaptopでのキャッシュ利用を確認済み。
12時間ごとの定期更新は実装済みで、実機での初回実行待ち。

目的:

- CIで事前buildした成果物の再利用
- ノートPC等のbuild時間短縮
- 複数NixOSホストでのclosure共有

Binary Cacheが停止してもNixクライアントは通常のビルドへフォールバック可能とする。

### 容量管理

Nix StoreのGCとBinary Cacheのretentionは別に管理する。

例:

- Nix Store:
  - 30日以上古い不要generationを定期GC
- Binary Cache:
  - 現在利用中のconfiguration
  - 最近の数世代
  - build costが高い成果物

を中心に保持する。

古いnixpkgs revisionの成果物を無制限に残さない。

---

## 10. Linuxカーネル高速ビルド環境

Ryzenはカーネル開発用ビルドマシンとして利用する。

目的:

- カーネルパッチの開発
- 短時間での再コンパイル
- NixOS用カーネルパッチ検証

ディレクトリ例:

```text
/srv/kernel/
├── linux/
├── build/
├── build-test/
└── ccache/
```

通常のパッチ開発ではNix derivationを毎回使用しない。

開発ループ:

```mermaid
flowchart LR
    Source["Linux source"]
    Patch["Patch"]
    Build["Persistent O= build tree"]
    Cache["ccache"]
    Kernel["Kernel image"]

    Source --> Patch
    Patch --> Build
    Cache <--> Build
    Build --> Kernel
```

基本方針:

- 最初に、Nix経由のパッチ付きカーネルビルドでRyzen上の永続ccacheを利用できるようにする。
- 手動の開発ループ用環境は、カーネルパッチの反復開発が必要になった段階で追加する。
- `make O=/srv/kernel/build`
- `-j16`
- ccache利用
- build directoryを永続化
- 差分コンパイルを最大限利用

パッチ完成後のみNix側へ取り込み、再現可能な正式buildを行う。

```mermaid
flowchart LR
    Dev["Kbuild + ccache"]
    Patch["完成patch"]
    Nix["Nix derivation"]
    CI["CI build"]
    Cache["Binary Cache"]

    Dev --> Patch
    Patch --> Nix
    Nix --> CI
    CI --> Cache
```

---

## 11. NixOS構成管理

RyzenとROCKは同一flake内で管理する。

想定構成:

```text
nixos/
├── flake.nix
├── hosts/
│   ├── ryzen/
│   │   ├── default.nix
│   │   └── hardware.nix
│   └── rock3b/
│       ├── default.nix
│       └── hardware.nix
├── modules/
│   ├── common/
│   ├── cloudflare.nix
│   ├── nginx.nix
│   ├── forgejo.nix
│   ├── runner.nix
│   ├── nix-builder.nix
│   └── monitoring.nix
└── secrets/
```

共通設定はmodule化し、ホスト固有設定を最小化する。

Ryzen:

```text
common
cloudflare
nginx
forgejo
runner
nix-builder
monitoring
```

ROCK:

```text
common
cloudflare
nginx
monitoring
```

---

## 12. 監視・保守

Ryzen側:

- SMART監視
- mdadm RAID整合性チェック、縮退状態・再同期状態の監視
- Nix GC
- Binary Cache retention
- ディスク使用量監視
- nginx health check
- cloudflared状態監視

ROCK側:

- nginx health check
- cloudflared状態監視
- Web release確認
- UPS環境での再起動試験

---

# 13. 実装ロードマップ

## Phase 0: ハードウェア準備

Ryzen機を組み立てる。

作業:

- NVMe 500GB ×2搭載
- RAM搭載
- Ethernet接続
- BIOS設定確認
- NixOS installer起動確認

完了条件:

- 両NVMeを正常認識する。
- Memtest等でRAM異常がない。
- Ethernetが安定している。

---

## Phase 1: Ryzen基盤構築

状態: **完了（2026-09-27）**。

NixOSを導入し、通常起動、LANおよびCloudflare Mesh経由のSSH、片側縮退起動とメンバー復旧を実機で確認した。
縮退のログ検出と縮退中の書き込み保持を確認し、B側は手動の再参加、A側は自動復旧を実施した。
SSDの再参加・交換と起動領域の復旧は[復旧手順](docs/ryzen-storage-recovery.md)にまとめる。
実機で遭遇したRAID管理情報のカーネル互換性問題は、7.2.7での正常起動を確認して解消した。

確定方針:

- ディスク暗号化なし。
- mdadm RAID1 + ext4を採用し、スナップショット・透過圧縮は使用しない。
- SSD片方の故障時も自動で縮退起動を行う。各SSDに独立したUEFI起動領域を用意する。
- LANアドレスはルーターのDHCP予約で固定する。
- 管理SSHはCloudflare Mesh経由およびLAN内から許可する。
- 障害検出は当面ログのみとし、通知は将来の監視UI導入時に再検討する。

作業:

- mdadm RAID1構築、ext4作成
- NixOSインストール
- SSH設定
- Cloudflare Mesh設定（公開HTTP用Tunnelは後続Phase）
- SMART監視
- mdadm RAID整合性チェックとログ記録
- Nix GC

完了条件:

- reboot後も正常起動する。
- どちらか片方のSSDが欠けた状態でも、手動操作なしで起動してSSH接続可能。
- 外部からCloudflare Mesh経由SSH可能。LAN内SSHも可能。
- RAID degraded状態を検出可能。
- 縮退中の書き込み後、メンバーの再参加・再同期が成功し、データを維持して再起動できる。
- NixOS configurationがGit管理されている。

---

## Phase 2: Nix Remote Builder

状態: **Ryzen適用・Mesh経由の小規模ビルド確認済み（2026-09-27）、ノートPC適用・残りの受入試験待ち**。

RyzenとノートPCの設定、専用鍵の暗号化管理、VM試験を追加した。
Ryzenへ適用し、専用鍵とホスト鍵検証を用いたMesh経由のビルド、およびクライアントへの成果物取得を確認した。
この確認はコマンド単位のbuilder指定で実施しており、ノートPCの恒久設定の適用、大規模ビルド、実機での途中切断試験は未実施。
適用順序と手動切替は[運用手順](docs/nix-remote-builder.md)にまとめる。

RyzenをRemote Builder化する。
設定方針は第8節に従い、通常は原則全委譲、障害時は手動でローカル実行へ切り替える。

作業:

- build専用ユーザー作成
- 専用SSH鍵のsops-nix管理とRyzenのホスト公開鍵固定
- クライアントの`nix.buildMachines`、distributed builds、`builders-use-substitutes`設定
- 通常時のローカルビルド無効化とRyzenの初期並列度設定
- 手動でのローカル実行手順の整備

テスト:

- rootとして専用鍵によるMesh経由の非対話接続とホスト鍵検証
- キャッシュ取得のみで終わらない小規模packageのリモートビルド
- 大規模packageのリモートビルドとメモリ使用量の確認
- NixOS configurationのビルド（実機への適用は含めない）
- Ryzenへ接続できない状態での失敗と、手動指定によるローカルビルド
- ビルド途中の接続断での失敗と、ローカルでの再実行
- Ryzen復旧後、通常のコマンドでリモートビルドへ戻ること

完了条件:

- 通常の`nix build`が必要とするビルドを原則Ryzenで実行し、ログで委譲を確認できる。
- Ryzen停止時に`--builders '' --max-jobs 1`の指定でローカルビルド可能。
- 途中切断後も手動で再実行でき、透過的な自動再実行は要求しない。

---

## Phase 3: Kernel Build Environment

状態: **再開方針確定（2026-09-30）、実装・実機検証は未実施**。

当面の目的は、laptopで使用するAX210用パッチ付きカーネルの`nixos-rebuild`に伴う再ビルドの高速化。
将来はROCK 3B向けなど、Wi-Fiモジュール以外のカーネル本体へのパッチも想定する。
2026-09-28には手動ビルド環境だけでは通常の`nixos-rebuild`の高速化に直結しないため保留したが、
今回はNix経由のカーネルビルドでRyzen上の永続ccacheを利用する構成から着手する。
公式カーネルとパッチ付きWi-Fiモジュールの単体ビルドを組み合わせる方式は代替案として残す。

初期作業:

- Ryzen上に永続ccache領域を用意し、容量上限とビルドユーザーのアクセス権限を設定する。
- 対象カーネルにccacheラッパーを適用し、Nix sandboxからキャッシュを利用できるようにする。
- laptopのパッチ付きカーネルをRyzenへ委譲する構成に組み込む。
- ビルド時間とccache統計の確認手順を整備する。

受入試験:

1. キャッシュ未蓄積時のカーネルビルド成功と所要時間を確認する。
2. 小さなパッチ変更で別derivationを生成して再ビルドし、ccacheのヒット率と所要時間を比較する。
3. 変更したパッチが成果物に反映されることを確認する。
4. laptopへ適用し、起動とAX210の動作を確認する。

初期完了条件:

- `nixos-rebuild`で利用するパッチ付きカーネルをRyzenでビルドできる。
- パッチ変更後の再ビルドでccacheのヒットと所要時間の短縮を確認できる。
- パッチの反映、laptopの起動とAX210の動作を確認できる。

後続拡張（初期完了条件には含めない）:

- 反復開発用のLinux source、永続`O=` build directory、build scriptとtoolchainを用意する。
- full build、1ファイル修正後の差分ビルド、パッチ適用後のkernel生成を確認する。
- ROCK 3B向けarm64カーネルのビルド方式を選定し、必要に応じてRyzen上のクロスコンパイル環境を追加する。
- x86_64とarm64それぞれでccacheの効果を検証する。異なるターゲット間のキャッシュ再利用は前提にしない。

---

## Phase 4: Forgejo移行

状態: **移行完了（2026-09-29）、ROCK本体停止試験のみ未実施**。

Forgejo 16.0.5 / SQLiteを維持し、保存先を`/srv/forgejo`、Web URLを
`https://git.floating-gate.com/`、Git SSHをMesh上の`ryzen.home.arpa:2222`へ変更した。
ROCKのForgejo・Runner・dumpを停止してデータを移し、Ryzenで起動・公開した。
専用Tunnel `ryzen-homelab` の認証JSON配置・DNS登録も完了。
新URLでのログイン・リポジトリ表示、SSHでのclone/push/pull、GitHub push mirror成功を確認した。
定期dumpの作成成功と毎日03:30の実行予約も確認済み。

laptopのSSH恒久設定は`~/nixos-config`の`93f5be4`でコミット済み（OSへの適用完了は未確認）。
既存リポジトリ`~/Projects/floating-gate`のoriginも新SSH URLへ変更し、参照取得を確認した。
詳細と再移行時の手順は[Forgejo移行手順](docs/forgejo-migration.md)にまとめる。

完了条件の確認状況:

- [x] clone/push/pull成功
- [x] GitHub mirror成功
- [ ] ROCK本体の停止状態でもForgejo利用可能（未試験）

残件の扱い:

- ROCK側の自動起動無効化・設定整理は利用者の方針で保留。サービスの停止と本体停止は区別する。
- 既存Runnerの接続先更新・再開は未実施。RyzenへのRunner移行はPhase 5で行う。
- 定期dumpからの復元確認と別ホストへの暗号化バックアップは保守課題として残す。
- 実用上の移行は完了とし、上記を記録したうえでPhase 5へ進む。

---

## Phase 5: Actions Runner

状態: **完了（2026-09-29）。workflowのmain統合もPhase 6で完了**。

`~/Projects/floating-gate`を対象に、Podman上のNode 22でWebビルドを行う。
既存デプロイjobとはRunnerラベルを分け、公開ディレクトリへの書き込み権限を付与しない。
Nix build用workflowは現時点では不要のため、今回の作業・完了条件から除外する。
登録と受入確認は[Actions Runner手順](docs/forgejo-runner.md)にまとめる。
`phase5-ci`ブランチでWebビルド成功、意図的なCI失敗時の本番release維持、復旧後の再成功を確認した。
Podman 5.8.7との互換性のためNode 22 Alpineを使い、ブリッジのDNS通信を許可する。
workflowの`main`統合は、既存deploy workflowを整理したPhase 6で完了した。

RyzenにForgejo Actions Runnerを配置する。

作業:

- Runner登録
- build環境構築
- CI workflow作成

初期CI:

```text
push
↓
Forgejo
↓
Runner
↓
build
```

完了条件:

- Web build成功
- Nix buildは今回スキップ（workflowが必要になった時点で追加）
- CI失敗時に本番環境へ影響しない

---

## Phase 6: Ryzen Web Deployment

状態: **完了（2026-09-29）**。

既存のROCK用nginx構成とサイト側`deploy.sh`を再利用する。
Ryzenに`/srv/www/floating-gate`と`/healthz`、既存TunnelへのWeb ingressを追加した。
既存Runnerのvolume許可をサイト領域に限定し、本番jobでのみマウントする。
サイト側workflowはAlpine対応・新Forgejo URL・Ryzen Runnerへ更新し、mainの二重ビルドを除いた。
適用順序と切戻しは[Webデプロイ手順](docs/web-deployment.md)を参照。
サイトの`9dbfeb7`をmainへpushし、[CI #77](https://git.floating-gate.com/jinji/floating-gate/actions/runs/77)が成功。
Ryzenの`current`が同commitを指し、`/healthz`が200 / ok、HTTP本文と公開ファイルのハッシュ一致を確認した。
DNS切替後の公開アクセスを確認済み。
[CI #78](https://git.floating-gate.com/jinji/floating-gate/actions/runs/78)で意図的にビルドを失敗させ、
旧release・HTTP本文・公開healthzの維持を確認した。
試験変更をrevertした`557c62c`の[CI #79](https://git.floating-gate.com/jinji/floating-gate/actions/runs/79)は成功し、
新releaseへの切替と公開サイトの正常応答を確認した。
途中状態の非公開は隔離環境のコピー途中・失敗試験とnginx VM試験でも確認済み。

RyzenへのWeb自動デプロイを構築する。

作業:

- nginx
- releases構成
- atomic symlink deployment
- `/healthz`

完了条件:

- [x] Git pushから本番反映まで自動化
- [x] build失敗時は既存release維持
- [x] deploy途中状態が公開されない

---

## Phase 7: Nix Binary Cache

Binary Cacheを導入する。

状態: **push時CI・キャッシュ利用を実機確認、定期更新を実装（2026-10-06）**。
Nix標準のファイルキャッシュをnginxと既存Cloudflare Tunnelで配信する。
署名付きclosure公開コマンド、公開鍵を投入して有効化するlaptop設定、基盤のVM試験を追加。
署名鍵生成・DNS追加・署名付きprobe取得、laptop設定適用、Forgejoへの正本移行を確認済み。
専用Runnerとmainへのpush時のlaptop構成ビルド・署名付きclosure公開を実装。
Runnerの初回CI成功とlaptopでのキャッシュ利用を利用者が確認済み。
09:00・21:00 JSTの定期更新、公開・検証後だけのpush、競合時の再ビルドを実装。
定期更新の実機実行とretentionは未実施。

作業:

- Cache server導入
- signing key
- クライアント設定
- CI連携
- retention設定
- `nixos-config`の正本をForgejoへ移行
- 12時間ごとのlock更新・laptop構成の事前ビルド・キャッシュ公開後のpush
- 設定変更push時のlaptop構成ビルド・公開

完了条件:

- CI成果物を他端末が取得可能
- 同じコミットのlaptop構成をfish completionsも含めて取得可能
- 定期更新失敗時に更新コミットを公開せず、前回成功分を維持
- Cache停止時も通常build可能

---

## Phase 8: ROCK 3B再構築

既存ROCK環境を廃止し、待機系として再構築する。

作業:

- 最小NixOS
- nginx
- cloudflared
- OpenSSH
- Web release領域

削除:

- Forgejo
- Runner
- 不要コンテナ
- 不要GUI
- Git backup

完了条件:

- ROCK単体でWeb配信可能
- UPS環境で安定して再起動可能

---

## Phase 9: Dual Deployment

RunnerからRyzenとROCKへ同じWeb成果物を配布する。

作業:

```text
build
├── deploy Ryzen
└── deploy ROCK
```

完了条件:

- 両ホストへのdeploy成功時はrelease ID一致
- ROCK側で独立してWeb配信可能
- 一方へのdeploy失敗を検出可能
- ROCK停止中のdeploy失敗は許容し、Ryzenへのdeployと後続処理を継続する
- ROCK復帰後も、明示的な命令がない限り自動同期しない

---

## Phase 10: Web Failover

Cloudflare側で自動切替を実装する。

監視対象:

- nginx
- cloudflared
- Ryzen host

障害試験:

1. `systemctl stop nginx`
2. `systemctl stop cloudflared`
3. Ryzen shutdown
4. Ethernet切断

それぞれについて:

```text
Ryzen
↓ failure
ROCK
↓ Ryzen recovery
Ryzen
```

が成立することを確認する。

完了条件:

- Ryzen停止時にWeb公開継続
- ROCKは通常時の通信経路に入らない
- Ryzen復旧後に主系へ戻せる

---

# 14. 最終受入条件

以下をすべて満たした時点で構築完了とする。

## 平常運用

- WebがRyzenから配信される。
- Forgejoが利用できる。
- Actions Runnerが利用できる。
- Remote Buildが利用できる。
- Binary Cacheが利用できる。
- ROCKを停止しても平常サービスに影響しない。

## Ryzen障害時

- WebがROCKから配信される。
- Forgejo停止は許容。
- Runner停止は許容。
- Remote Build停止は許容。
- Nix clientが手動指定でlocal build可能（自動切替は要求しない）。
- Binary Cache停止は許容。

## データ保全

- Git repositoryがGitHubへmirrorされる。
- 両ホストへのデプロイ成功時は、Webの同一releaseが存在する。ROCK停止中のデプロイ失敗によるreleaseの不一致は許容し、復帰後も明示的な命令がない限り自動同期しない。
- NVMe 1台故障時もRyzenを継続運用可能。

## 保守性

- RyzenとROCKを同一flakeで管理できる。
- Host固有設定と共通moduleが分離されている。
- Nix StoreとBinary Cacheを定期的に整理できる。
- Kernel buildを差分コンパイル可能。

---

# 15. 実装優先順位

Phase 4〜6の実用到達を経て、次はPhase 3を再開する。
まずNix経由のパッチ付きカーネルビルドへのccache導入を進め、その後はPhase 7以降へ進む。
Phase 3の手動開発環境とarm64対応は、必要になった段階で追加する。

```text
Ryzen基盤
  ↓
Nix Remote Builder
  ↓
Forgejo
  ↓
Actions Runner
  ↓
Ryzen Web Deployment
  ↓
Kernel Build Environment（Phase 3再開: Nixビルドへのccache導入）
  ↓
Nix Binary Cache
  ↓
ROCK再構築
  ↓
Dual Deployment
  ↓
Web Failover
```

最初の実用到達点は、

> ノートPCからRyzenへNix Remote Buildできる状態

とする。

次の到達点は、

> ForgejoへのpushからRyzenへのWeb deployが自動実行される状態

最終到達点は、

> Ryzenを完全停止してもROCK 3BからWebだけは継続公開される状態

とする。
