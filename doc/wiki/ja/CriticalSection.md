# CriticalSection
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp メッセージシリアライゼーションキュー

---

```lua
local queue = require "skynet.queue"
```

同一の skynet-cpp サービス内で 1 つのメッセージ処理中にブロッキング API（`skynet.call` など）を呼び出すと、処理はサスペンドされます。サスペンド中もサービスは他のメッセージに応答できます。これにより順序の問題が発生する可能性があるため、非常に注意深く対処する必要があります。

つまり、メッセージ処理に外部リクエストが含まれる場合、先に到着したメッセージが先に処理完了するとは限りません。各ブロッキング呼び出しの後、サービスの内部状態は呼び出し前と異なる可能性があります。

`skynet.queue` モジュールは、この擬似並行に起因する複雑性を回避するのに役立ちます。

---

## 使い方

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs は実行キュー

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 がクリティカルセクションに入る
end

function CMD.foo()
    cs(func2)  -- func2 がクリティカルセクションに入る
end
```

`cs` キューを使用すると、`func1` と `func2` は実行中に互いに中断されません。

サービスが複数の `foobar` または `foo` メッセージを受信した場合、`func1` や `func2` 内に `skynet.call` のようなブロッキング呼び出しがあっても、必ず 1 つの処理が完了してから次の処理に入ります。

---

## リエントランシー

func1 内部で cs を再度呼び出すことは合法です（デッドロックしません）：

```lua
local function func2()
    -- step 3
end

local function func1()
    -- step 2
    cs(func2)
    -- step 4
end

function CMD.foobar()
    -- step 1
    cs(func1)
    -- step 5
end
```

foobar メッセージ受信のたびに、プログラムフローは step 1 → 2 → 3 → 4 → 5 の順に実行されます。

---

## 実装原理

queue は以下の機構で FIFO スケジューリングを実現しています：

- `current_thread`：現在ロックを保持しているコルーチンを記録
- `ref` 参照カウント：同一コルーチンのネスト呼び出しをサポート（リエントランシー）
- `thread_queue` 待機キュー：新しいリクエストはキューの末尾に追加
- `skynet.wait()` / `skynet.wakeup()` を利用してコルーチン間のサスペンドと起動を実現

---

## オリジナル skynet との差異

- API は完全に同一
- 実装方式も同一（skynet.wait/wakeup ベース）

