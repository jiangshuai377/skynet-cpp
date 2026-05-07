# Multicast
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp パブリッシュ/サブスクライブ

---

```lua
local multicast = require "skynet.multicast"
```

Multicast モジュールは同一プロセス内でのチャネルベースのパブリッシュ/サブスクライブメッセージ機構を提供します。

---

## 使い方

### パブリッシャー

```lua
local multicast = require "skynet.multicast"

-- 新しいチャネルの作成
local mc = multicast.new()
print("channel id:", mc.channel)

-- メッセージの発行（fire-and-forget）
mc:publish("event_name", { data = 123 })

-- チャネルの削除
mc:delete()
```

### サブスクライバー

```lua
local multicast = require "skynet.multicast"

-- 既存のチャネル ID を使用
local mc = multicast.new({ channel = channel_id })

-- 受信コールバックの設定
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- サブスクライブ
mc:subscribe()

-- サブスクライブ解除
mc:unsubscribe()
```

---

## API

| メソッド | 説明 |
|---|---|
| `multicast.new(opts)` | チャネルオブジェクトを作成。opts に `{channel=id}` を含めると既存チャネルを使用 |
| `mc:subscribe()` | 現在のサービスをこのチャネルにサブスクライブ |
| `mc:unsubscribe()` | サブスクライブ解除 |
| `mc:publish(...)` | すべてのサブスクライバーにメッセージを発行 |
| `mc:delete()` | このチャネルを削除 |
| `mc.dispatch` | コールバック関数として設定し、発行されたメッセージを受信 |

---

## 実装アーキテクチャ

| コンポーネント | 説明 |
|---|---|
| `multicastd` サービス | ユニークサービス。チャネル ID 割り当て、サブスクライバーリスト、メッセージブロードキャストを管理 |
| `multicast.lua` クライアント | `PTYPE_MULTICAST` プロトコルタイプを登録し、オブジェクト指向 API を提供 |

メッセージ発行フロー：
1. パブリッシャーが `mc:publish(...)` を呼び出す
2. メッセージが `multicastd` サービスに送信される
3. `multicastd` がサブスクライバーリストを巡回し、各サブスクライバーに `PTYPE_MULTICAST` メッセージを送信
4. サブスクライバーの dispatch コールバックがトリガーされる

---

## オリジナル skynet との差異

- API は基本的に同一
- オリジナルはノード間マルチキャスト（datacenter 経由で配布）をサポートするが、skynet-cpp は同一プロセス内のみ対応

