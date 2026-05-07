# Socket
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp Socket API

---

```lua
local socket = require "socket"
```

skynet-cpp は TCP/UDP の読み書きのためのブロッキングモード Lua API セットを提供しています。ブロッキングモードといっても、実際には Lua の coroutine 機構を活用しています。socket API を呼び出すと、サービスはサスペンドされる可能性があり（タイムスライスを他のビジネス処理に譲渡）、socket メッセージを通じて結果が返ると、coroutine が実行を継続します。

---

## TCP API

### サーバー側

```lua
-- ポートの監視
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- 新規接続受け入れ
    elseif event == "close" then
        -- 接続切断
    elseif event == "warning" then
        -- 送信バッファ警告
    end
end)

-- データコールバックの設定
socket.ondata(listener_id, function(conn_id, data)
    -- データ受信
end)
```

- `socket.listen(host, port, handler)` — ポートを監視し、handler が accept/close/warning イベントを受信、listener_id を返す
- `socket.ondata(listener_id, handler)` — データコールバックを設定 `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — listener の接続上でデータを送信
- `socket.close_listener(listener_id)` — 監視を閉じる
- `socket.pause(listener_id, conn_id)` — 接続の読み取りを一時停止（フロー制御）
- `socket.resume(listener_id, conn_id)` — 接続の読み取りを再開

### クライアント側

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — リモートホストに接続。接続確立または失敗までブロック
- `socket.send(conn_id, data)` — データを送信
- `socket.read(conn_id, sz)` — sz バイトを読み取り。データ準備完了または接続切断までブロック
- `socket.readline(conn_id, sep)` — 区切り文字まで読み取り（デフォルト `"\n"`）。区切り文字は含まない
- `socket.readall(conn_id)` — 利用可能なすべてのデータを読み取り
- `socket.close(conn_id)` — 接続を閉じる

---

## UDP API

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- UDP パケット受信
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — UDP socket を作成。コールバックがパケットを受信
- `socket.udp_send(id, data, host, port)` — UDP パケットを送信

---

## socketdriver (C モジュール)

`socket.lua` は低レベル C モジュール `socketdriver` のコルーチンラッパーです。`socketdriver` が登録する関数は以下の通りです：

| 関数 | 説明 |
|---|---|
| `socketdriver.listen(host, port, backlog)` | TCP 監視を作成 |
| `socketdriver.connect(host, port)` | TCP 接続を作成（非同期） |
| `socketdriver.send(id, data)` | connector 経由でデータを送信 |
| `socketdriver.write(listener_id, conn_id, data)` | listener の接続経由で送信 |
| `socketdriver.close(id, [conn_id])` | socket または接続を閉じる |
| `socketdriver.pause(listener_id, conn_id)` | 接続の読み取りを一時停止 |
| `socketdriver.resume(listener_id, conn_id)` | 接続の読み取りを再開 |
| `socketdriver.udp(host, port)` | UDP socket を作成 |
| `socketdriver.udp_send(id, data, host, port)` | UDP を送信 |

---

## オリジナル skynet との差異

- オリジナルは `socket.start(id)` で socket の制御権を引き継ぐ（複数サービスが socket id を共有するため）が、skynet-cpp の listener/connector は作成したサービスに自然にバインドされる
- オリジナルには `socket.abandon`（制御権の移譲）があるが、skynet-cpp では未実装
- オリジナルには `socket.lwrite`（低優先度書き込みキュー）があるが、skynet-cpp では未実装
- オリジナルには `socket.block`（読み取り可能待ち）があるが、skynet-cpp では未実装

