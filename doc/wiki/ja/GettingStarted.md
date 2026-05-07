# GettingStarted
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp 入門ガイド

---

## フレームワーク

skynet-cpp は軽量な Actor モデルサーバーフレームワークです。シンプルなオペレーティングシステムとして捉えることができ、数千の Lua 仮想マシンをスケジューリングし、並行動作させることができます。各 Lua 仮想マシンは、他の仮想マシンから送信されたメッセージを受信・処理したり、他の仮想マシンにメッセージを送信したりできます。

skynet-cpp には外部ネットワークデータ入力とタイマーの管理機能が組み込まれており、これらを統一的なメッセージとして各サービスに入力します。

### オリジナル skynet との関係

skynet-cpp の設計理念と API セマンティクスは完全に [cloudwu/skynet](https://github.com/cloudwu/skynet) に由来していますが、C++20 で基盤フレームワークを再実装しています。Lua 開発者にとっては、API の使い方はオリジナルの skynet とほぼ同一です。

---

## サービス (Service)

skynet-cpp のサービスは Lua で記述します。規約に準拠した `.lua` ファイルを skynet-cpp が見つけられるパスに配置するだけで、他のサービスから起動できます。各サービスにはフレームワークが割り当てるユニークな 32bit アドレス（handle）があります。

各サービスには 3 つの実行フェーズがあります：

1. **ロードフェーズ**：サービスのソースファイルがロードされ実行されます。このフェーズではブロッキング API を呼び出す**ことはできません**。
2. **初期化フェーズ**：`skynet.start(func)` で登録された初期化関数が実行されます。このフェーズでは任意の skynet API を呼び出せます。このサービスを起動した `skynet.newservice` は初期化完了を待機します。
3. **動作フェーズ**：初期化完了後、メッセージハンドラを登録したサービスはメッセージへの応答を開始します。

```lua
local skynet = require "skynet"

-- ロードフェーズ：モジュールレベル変数の設定
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- 初期化フェーズ：メッセージディスパッチの登録
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## メッセージ (Message)

各 skynet-cpp メッセージは以下の要素で構成されます：

1. **session**：リクエストを発行したサービスが生成するユニーク識別子。応答側は応答時に session を持ち帰り、送信側はこれによりリクエストと応答を照合します。session が 0 の場合は応答不要（一方向プッシュ）です。
2. **source**：メッセージ送信元のサービスアドレス（32bit handle）。
3. **type**：メッセージカテゴリ。最もよく使われるのは `"lua"` で、Lua サービス間通信用です。
4. **message + size**：メッセージ内容（C ポインタ + 長さ）、シリアライズ関数によって生成されます。

### メッセージタイプ

| タイプ | 名前 | 用途 |
|---|---|---|
| 0 | `text` | プレーンテキストメッセージ |
| 1 | `response` | RPC 応答 |
| 6 | `socket` | ネットワークイベント |
| 7 | `error` | エラー通知 |
| 10 | `lua` | Lua シリアライズメッセージ（最も一般的）|

---

## コルーチンスケジューリング

低レベルから見ると、各サービスは 1 つのメッセージプロセッサです。しかしアプリケーション層では、Lua の coroutine を活用して動作します。

サービスが別のサービスにリクエストを送信（`skynet.call`）すると、現在のコルーチンはサスペンドされます。相手がリクエストを受信して応答を返すと、フレームワークはサスペンドされたコルーチンを見つけ、応答情報を渡して以前の処理フローを継続します。利用者の視点からは、独立したスレッドがビジネスロジックを処理しているように見えます。

**リエントランシーに注意**：サービスがあるビジネスフロー中にサスペンドされた後も、他のメッセージを処理できます。そのため、`skynet.call` の前に取得したサービス内部状態は、戻り時には変更されている可能性があります。2 つのブロッキング API 呼び出しの間の実行は原子的です。[CriticalSection](CriticalSection.md) を使用して、擬似並行に起因する複雑性を軽減できます。

---

## ネットワーク

skynet-cpp にはネットワーク層が組み込まれており、TCP と UDP の機能をカプセル化しています。サービス内でシステムネットワーク API を直接操作するモジュールの使用は推奨しません。ネットワーク IO でブロックされると、ワーカースレッド全体に影響するためです。

skynet-cpp 組み込みの [Socket](Socket.md) API を使用すれば、ネットワーク IO ブロック時に CPU 処理能力を完全に開放できます。

クライアント接続の管理には [GateServer](GateServer.md) ゲートウェイサービスの使用を推奨します。

---

## 外部サービス

skynet-cpp は [Redis](ExternalService.md#redis-驱動)、[MySQL](ExternalService.md#mysql-驱動)、[MongoDB](ExternalService.md#mongodb-驱動) のドライバモジュールを提供しています。これらのドライバモジュールはすべて [SocketChannel](SocketChannel.md) をベースに実装されており、skynet-cpp と良好に協調動作します。

---

## クラスタ

skynet-cpp はノード間 RPC をサポートする cluster モードを実装しています。詳細は [Cluster](Cluster.md) を参照してください。

オリジナルの skynet とは異なり、skynet-cpp は master/slave モード（harbor モード）を**サポートしていません**。すべて cluster モードの使用を推奨します。

---

## オリジナル skynet との差異

- master/slave (harbor) モードは**非対応**
- Snax フレームワークは**非対応**
- Sproto プロトコルは**非対応**
- DataCenter は**非対応**（廃止済み）
- ShareData はメッセージパッシングによるディープコピーを使用（C 共有メモリではない）
- Lua 5.5.0 を使用（オリジナルは Lua 5.4）
- データベースドライバ（BSON/SHA1）はすべて純 Lua 実装

