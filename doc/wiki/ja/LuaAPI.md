# LuaAPI
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet Lua サービス API リファレンス

---

```lua
local skynet = require "skynet"
```

各 skynet-cpp サービスは `skynet` モジュールをインポートする必要があります。このモジュールは skynet-cpp フレームワーク外では使用できません。

---

## サービスアドレス

各サービスには 32bit の数値アドレス（handle）があります。

- `skynet.self()` — 現在のサービスアドレスを返す
- `skynet.address(addr)` — アドレスを可読文字列に変換（`:xxxxxxxx` 形式）
- `skynet.register(name)` — 現在のサービスにエイリアスを登録（`.` で始まるものはローカル名）
- `skynet.name(name, handle)` — 指定 handle のサービスにエイリアスを登録
- `skynet.localname(name)` — ローカル名に対応するアドレスを照会（ノンブロッキング）

サービスアドレスを受け付けるすべての API パラメータには、文字列エイリアスも渡せます。

---

## メッセージディスパッチと応答

### skynet.dispatch(type, func)

特定カテゴリのメッセージ処理関数を登録します。最も一般的な書き方：

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

新しいメッセージカテゴリを登録します。class には `name`、`id`、`pack`、`unpack` フィールドが必要です。

### skynet.ret(msg, sz)

現在のリクエスト元にメッセージを応答します。同一のメッセージ処理 coroutine 内で一度だけ呼び出せます。

### skynet.retpack(...)

`skynet.ret(skynet.pack(...))` のショートカットです。

### skynet.response([packfunc])

遅延応答クロージャを生成し、将来別のコルーチンで呼び出せます。

```lua
local resp = skynet.response()
-- 後で別の場所で呼び出す：
resp(true, result1, result2)   -- 正常応答
resp(false)                     -- リクエスト元に例外をスロー
```

---

## メッセージプッシュとリモート呼び出し

### skynet.send(addr, typename, ...)

addr に typename タイプのメッセージを送信します。ノンブロッキング API で、メッセージは pack 関数でパッキングされます。

### skynet.call(addr, typename, ...)

addr にリクエストを送信し、応答をブロッキングで待機します。応答は unpack でデシリアライズされて返されます。**注意**：`skynet.call` は現在のコルーチンのみをブロックし、サービスは引き続き他のメッセージに応答できます。

### skynet.rawsend(addr, typename, msg, sz)

pack パッキングを経由しない生送信です。

### skynet.rawcall(addr, typename, msg, sz)

pack/unpack を経由しない生 RPC 呼び出しです。

### skynet.redirect(addr, source, typename, session, ...)

source アドレスに偽装して addr にメッセージを送信します。

---

## 時計とスレッド

内部時計の精度は 1/100 秒（センチ秒）です。

- `skynet.now()` — プロセス起動からの経過時間を返す（センチ秒）
- `skynet.starttime()` — プロセス起動時の UTC 時間を返す（秒）
- `skynet.time()` — 現在の UTC 時間を返す（秒、精度 10ms）

### skynet.sleep(ti)

現在のコルーチンを ti センチ秒サスペンドします。`"BREAK"` を返す場合は `wakeup` によって起こされたことを示します。

### skynet.yield()

`skynet.sleep(0)` と等価です。CPU 制御権を譲渡します。

### skynet.timeout(ti, func)

ti センチ秒後に新しいコルーチンで func を実行します。ノンブロッキング API です。

### skynet.fork(func, ...)

新しいコルーチンで func を起動します。`timeout(0, ...)` より効率的です（タイマーを経由しないため）。

### skynet.wait(token)

現在のコルーチンをサスペンドし、`wakeup` による起動を待ちます。token のデフォルトは `coroutine.running()` です。

### skynet.wakeup(token)

`sleep` または `wait` でサスペンドされたコルーチンを起こします。

---

## サービスの起動と終了

### skynet.start(func)

サービスの起動関数を登録します。**必ず呼び出す必要があります**。サービスのエントリポイントです。

### skynet.exit()

現在のサービスを終了します。以降のコードは実行されず、サスペンド中のコルーチンも中断されます。

### skynet.newservice(name, ...)

新しい Lua サービスを起動します。ブロッキング API で、起動されたサービスの `start` 関数が戻るまで待機します。

### skynet.uniqueservice(name, ...)

ユニークサービスを起動します。すでに起動済みの場合は既存のアドレスを返します。

### skynet.queryservice(name)

ユニークサービスのアドレスを照会します。まだ起動されていない場合は待機します。

## Path Configuration

These APIs are normally called from the preload script. Each argument is a plain directory path; the runtime normalizes `/`, `\`, duplicate separators, and trailing separators, then expands Lua/C module or service search rules internally. Newly created LuaActors inherit the current global path snapshot.

- `skynet.appendpath(path)` — Append a Lua module directory, expanded to `path/?.lua` and `path/?/init.lua`.
- `skynet.prependpath(path)` — Prepend a Lua module directory.
- `skynet.appendcpath(path)` — Append a C module directory, expanded to the platform `.dll` or `.so` search pattern.
- `skynet.appendservicepath(path)` — Append a service script directory, expanded to `path/?.lua`.
- `skynet.getpath()` — Return the current `{ path, cpath, service_path }` snapshot.
- `skynet.getcwd()` — Return the process current working directory for preload logging and path debugging.
- `skynet.setpathbase(path)` — Set the relative base used by path APIs without changing the OS cwd.
- `skynet.getpathbase()` — Return the current pathbase.
- `skynet.readfile(path)` / `skynet.writefile(path, data, append)` — Controlled file read/write helpers that resolve paths from pathbase.
- `skynet.systemstat()` — Return process-level runtime stats such as actor count, global queue backlog, and worker count.

---

## シリアライゼーション

- `skynet.pack(...)` — Lua 値を `(lightuserdata, size)` にシリアライズ
- `skynet.unpack(msg, sz)` — Lua 値にデシリアライズ
- `skynet.packstring(...)` — Lua string にシリアライズ
- `skynet.tostring(msg, sz)` — lightuserdata を Lua string に変換
- `skynet.trash(msg, sz)` — lightuserdata バッファを解放

対応型：string, boolean, number, lightuserdata, table（メタテーブルなし）。

---

## ログ

### skynet.error(...)

引数を連結して logger サービスに送信します。出力形式：`[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## 状態照会

- `skynet.info_func(func)` — 内部状態照会関数を登録（debug プロトコルから呼び出される）
- `skynet.stat(what)` — サービスの内部状態を照会：`"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## その他

- `skynet.getenv(key)` — 環境変数を読み取り
- `skynet.setenv(key, value)` — 環境変数を設定（上書き不可）
- `skynet.genid()` — ユニークな session を生成
- `skynet.harbor(addr)` — 常に 0 を返す（skynet-cpp は harbor 非対応）

---

## オリジナル skynet との差異

- `skynet.harbor()` は常に 0 を返す
- `skynet.forward_type` と `skynet.filter`（高度なメッセージ転送）は非対応
- `skynet.memlimit` は `start` の前に呼び出す必要がある
- 環境変数は設定ファイルではなく `ActorSystem` 経由で渡される


