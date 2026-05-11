# GateServer
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp ゲートウェイサービステンプレート

---

ゲートウェイサービス (GateServer) はアプリケーションのアクセス層であり、基本機能はクライアント接続の管理、完全なデータパケットの分割、ロジックサービスへの転送です。

skynet-cpp では汎用テンプレートとして `lualib/gateserver.lua` を提供しています。

---

## 使い方

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- 新規クライアント接続
end

function handler.disconnect(conn_id)
    -- クライアント切断
end

function handler.message(conn_id, data)
    -- 完全なビジネスデータパケット受信（長さヘッダ除去済み）
end

function handler.open(source, conf)
    -- Gate の監視ポート開放
end

gateserver.start(handler)
```

注：`gateserver.start` 内部で `skynet.start` が呼び出されます。

---

## Handler コールバック

| コールバック | シグネチャ | 説明 |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | 新規クライアントの accept 後に呼び出される |
| `disconnect` | `(conn_id)` | 接続切断時に呼び出される |
| `message` | `(conn_id, data)` | 完全なビジネスパケット（netpack により分割済み）到着 |
| `error` | `(conn_id, msg)` | 接続異常 |
| `warning` | `(conn_id, bytes)` | 送信バッファが 1M を超える警告 |
| `open` | `(source, conf)` | 監視ポート開放時に呼び出される |

---

## パケット分割プロトコル

各パケット = **2 バイトビッグエンディアン長さヘッダ** + **データ内容**

単一データパケットの最大サイズは 65535 バイトです。より大きなデータブロックを転送する必要がある場合は、上位プロトコルで対処してください。

### netpack API

```lua
local netpack = require "netpack"
```

| 関数 | 説明 |
|---|---|
| `netpack.pack(data)` | データをパッキング（2 バイト長さヘッダ付加）、フレーム化された string を返す |
| `netpack.unpack(buffer, offset)` | buffer から完全なフレームを抽出、(next_offset, payload) を返す |
| `netpack.filter(buffer, new_data)` | 新データを統合し、すべての完全なフレームを抽出 |
| `netpack.tostring(msg, sz)` | lightuserdata を Lua string に変換 |

---

## 制御コマンド

他のサービスは lua プロトコルを通じて gate に以下のコマンドを送信できます：

```lua
-- 監視を開始
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- 長さヘッダ付きデータを送信
skynet.call(gate, "lua", "SEND", conn_id, data)

-- 生データを送信（長さヘッダなし）
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- 接続を閉じる
skynet.call(gate, "lua", "CLOSE", conn_id)

-- 接続を切断
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## オリジナル skynet との差異

- オリジナルの gateserver は `lualib/snax/gateserver.lua` にあるが、skynet-cpp では `lualib/gateserver.lua` に配置
- オリジナルには `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` でメッセージ受信を制御する機能があるが、skynet-cpp の接続はデフォルトでメッセージを受信する
- オリジナルの message コールバックは C ポインタと長さ `(fd, msg, sz)` を渡すが、skynet-cpp は Lua string `(conn_id, data)` を渡す
- オリジナルでも socket ライブラリと同一サービス内で混用できないのと同様、skynet-cpp でも同様

