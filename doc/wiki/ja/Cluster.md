# Cluster
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp クラスタ

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp はノード間 RPC をサポートする cluster モードを実装しています。各ノードは独立した skynet-cpp プロセスであり、ノード間は TCP 接続を通じてメッセージをやり取りします。

---

## クイックスタート

### ノード A：リッスン + サービス提供

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- リモートアクセス用に名前を登録
    cluster.register("echo", echo)

    -- クラスタ設定をロード
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- リッスンポートを開く
    cluster.open("127.0.0.1", 19999)
end)
```

### ノード B：リモート呼び出し

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- ノード A の echo サービスを RPC 呼び出し
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- 登録名を照会
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| 関数 | 説明 |
|---|---|
| `cluster.call(node, addr, ...)` | リモートノードのサービスへの同期 RPC 呼び出し。応答をブロッキングで待機 |
| `cluster.send(node, addr, ...)` | リモートノードへの非同期メッセージプッシュ（応答なし）。メッセージ消失リスクあり |
| `cluster.open(addr, port)` | リッスンポートを開き、インバウンドクラスタ接続を受け入れ |
| `cluster.reload(cfg)` | クラスタ設定をリロード。cfg は `{nodename = "host:port", ...}` テーブル |
| `cluster.register(name, addr)` | ローカルサービス名を登録し、リモートから `@name` でアクセス可能にする。addr のデフォルトは自身 |
| `cluster.unregister(name)` | 登録済みの名前を登録解除 |
| `cluster.query(node, name)` | リモートノードで `cluster.register` により登録されたサービスアドレスを照会 |

### アドレス形式

`cluster.call` の第 2 パラメータ `addr` には以下が使用できます：

- **文字列名前**：例 `".echo"`、ターゲットノード上でこの名前を検索
- **`@` プレフィックス名前**：例 `"@echo"`、`cluster.register` で登録された名前を検索
- **数値アドレス**：リモートサービスの handle を既知の場合

---

## アーキテクチャ

cluster システムは 3 つのサービスで構成されます：

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ 本地服务
  (管理器)   (出站)                (入站)            ↓
      ▲                                          回应
      │                                            │
      └────────────────────── [TCP] ←───────────────┘
```

| サービス | 数量 | 役割 |
|---|---|---|
| `clusterd` | ノードごとに 1 | 中央マネージャ：設定、sender/agent ライフサイクル、名前登録、リッスン |
| `clustersender` | リモートノードごとに 1 | リモートノードへの TCP 接続を維持し、socketchannel でリクエストを送信 |
| `clusteragent` | 接続ごとに 1 | インバウンド接続を処理し、リクエストを解析してローカルサービスにディスパッチ、レスポンスを返送 |

---

## クラスタプロトコル

`cluster.core` C モジュールがクラスタワイヤプロトコルを実装しています：

- **パケット形式**：2 バイトビッグエンディアン長さヘッダ + ペイロード
- **リクエストパケット**：タイプマーカー + session + ターゲットアドレス + シリアライズされたメッセージ
- **レスポンスパケット**：session + 成功/失敗 + シリアライズされたメッセージ
- **大メッセージ分割**：32KB を超えるメッセージは自動的に複数セグメントに分割して転送

---

## メッセージ順序

クラスタ間のリクエストは大部分が呼び出し順に並びます（先着順）。ただし、単一パケットが 32KB を超える場合はパケットが分割転送され、大きなパケットが小さなパケットの後に到着する場合があります。

リクエストとレスポンスは同一の TCP 接続を使用するため、順序が保証されます。

---

## 設定の更新

`cluster.reload(cfg)` で設定をリロードします。ノードアドレスを変更した場合、リロード後の新しいリクエストは新しいアドレスに送信されます。完了前のリクエストは引き続き旧アドレスで待機します。

ノードアドレスを `false` に設定して、ノードをオフラインとしてマークできます。

---

## オリジナル skynet との差異

- skynet-cpp は master/slave (harbor) モードを**サポートしていません**。cluster のみ対応
- オリジナルの cluster 設定はファイルからロードするが、skynet-cpp では `cluster.reload(table)` でテーブルを渡す
- オリジナルには `cluster.proxy(node, addr)` でローカルプロキシを作成する機能があるが、skynet-cpp では未実装
- オリジナルには `cluster.snax` でリモート Snax サービスを扱う機能があるが、skynet-cpp は Snax 非対応
- オリジナルの設定は `__nowaiting = true` をサポートするが、skynet-cpp では未実装

