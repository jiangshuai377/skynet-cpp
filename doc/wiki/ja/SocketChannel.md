# SocketChannel
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp Socket 接続多重化

---

```lua
local socketchannel = require "skynet.socketchannel"
```

リクエスト/レスポンスパターンは外部サービスと通信する際に最もよく使われるパターンの 1 つです。socketchannel は高レベルのラッパーを提供し、2 つのプロトコル設計をサポートします：

1. **順序モード (Order Mode)**：各リクエストに対して 1 つのレスポンスが対応し、TCP が順序を保証（Redis など）
2. **セッションモード (Session Mode)**：各リクエストがユニークな session を持ち、レスポンスが session を持ち帰ってマッチング（MongoDB など）

---

## Channel の作成

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- 以下はオプションパラメータ：
    response = dispatch_func,   -- 指定するとセッションモードに入る
    auth = auth_func,           -- 接続確立後の認証コールバック
    nodelay = true,             -- TCP_NODELAY
}
```

socket channel は作成時に接続を即座に確立しません。接続は最初の `request` 時まで遅延されます。接続切断後、次の `request` で自動的に再接続します。

---

## 順序モード (Order Mode)

Redis のように各リクエストに対して必ず順序通りのレスポンスがあるプロトコルに適しています：

```lua
local resp = channel:request(req_string, function(sock)
    -- sock は channel が渡す読み取りオブジェクト
    local line = sock:readline()
    return true, line  -- 第1戻り値: 成功かどうか; 第2: レスポンス内容
end)
```

response 関数の第 1 戻り値は boolean です：
- `true`：プロトコル解析正常
- `false`：プロトコルエラー。接続が切断され、request が error をスロー

---

## セッションモード (Session Mode)

MongoDB のように結果が順不同で返されるプロトコルに適しています。作成時にグローバル `response` 関数を提供する必要があります：

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- レスポンスパケットの解析
        local session = ...  -- レスポンスから session を抽出
        local ok = true
        local data = ...     -- レスポンスデータの解析
        return session, ok, data
    end,
}

-- リクエスト送信時、response 関数の代わりに session を渡す
local resp = channel:request(req_string, session_id)
```

---

## 認証

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- 接続確立後に自動的に呼び出される
        -- AUTH / SELECT などの操作が可能
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

auth 関数は接続確立のたびに即座に実行されます。認証失敗時は auth 内で error をスローしてください。

---

## その他の API

| メソッド | 説明 |
|---|---|
| `channel:connect(once)` | 明示的に接続。once=true は 1 回だけ試行し、失敗時にエラーをスロー |
| `channel:close()` | channel を閉じ、待機中のすべての request を起こす |
| `channel:changehost(host, port)` | リモートアドレスを変更して再接続 |
| `channel:read(sz)` | channel から sz バイトを読み取り |
| `channel:readline(sep)` | channel から区切り文字で読み取り |
| `channel:response(func)` | リクエストを送信せず、レスポンスの受信のみを待機（pub/sub 用） |

---

## オリジナル skynet との差異

- API は基本的に同一
- オリジナルには `padding` パラメータと低優先度書き込み（`socket.lwrite`）があるが、skynet-cpp では未実装
- オリジナルには `backup` バックアップアドレス（mongo クラスタ向け）があるが、skynet-cpp では未実装
- オリジナルには `overload` 過負荷コールバックがあるが、skynet-cpp では未実装

