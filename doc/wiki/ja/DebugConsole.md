# DebugConsole
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp デバッグコンソールとデバッグプロトコル

---

## デバッグプロトコル

各 Lua サービスは自動的に `PTYPE_DEBUG` プロトコルを登録し、以下のデバッグコマンドを内蔵しています：

| コマンド | 説明 |
|---|---|
| `MEM` | 現在の Lua VM のメモリ使用量を返す（KB） |
| `GC` | ガベージコレクションを実行し、メモリ変化を報告 |
| `STAT` | タスク数、メッセージキュー長、CPU 統計を返す |
| `TASK` | タスクコルーチンのスタック情報を返す |
| `INFO` | サービスが登録した `info_func` コールバックを呼び出してカスタム情報を取得 |
| `EXIT` | サービスをグレースフルに終了 |
| `PING` | 生存確認（即座に応答） |
| `RUN` | Lua コードを注入して実行 |

### カスタムデバッグコマンドの登録

```lua
local skynet = require "skynet"
require "skynet.debug"

-- カスタム INFO コールバックの登録
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- カスタムデバッグコマンドの登録
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## デバッグコンソール

`debug_console.lua` は TCP telnet インターフェースを提供し、接続後にインタラクティブにデバッグコマンドを実行できます。

### 起動

```lua
-- preload.lua でデバッグコンソールを起動
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### 接続

```bash
telnet 127.0.0.1 8000
```

### コンソールコマンド

| コマンド | 引数 | 説明 |
|---|---|---|
| `help` | — | すべてのコマンドを一覧表示 |
| `list` | — | 実行中の全サービスを一覧表示 |
| `mem` | [timeout] | すべてのサービスのメモリ状態を照会 |
| `gc` | [timeout] | すべてのサービスで GC を実行 |
| `stat` | [timeout] | すべてのサービスの統計情報を照会 |
| `ping` | address | サービスの生存確認 |
| `info` | address, ... | サービスのカスタム情報を取得 |
| `exit` | address | 指定サービスをグレースフルに終了 |
| `kill` | address | 指定サービスを強制終了 |
| `start` | name, ... | 新しい Lua サービスを起動 |
| `inject` | address, code | サービスに Lua コードを注入して実行 |

---

## Profile パフォーマンス分析

```lua
local profile = require "skynet.profile"
```

`lua_profile.cpp` C モジュールによるコルーチンレベルの CPU タイミング：

| 関数 | 説明 |
|---|---|
| `profile.start([co])` | コルーチンのタイミングを開始（デフォルトは現在のスレッド） |
| `profile.stop([co])` | タイミングを停止し、CPU 時間（秒）を返す |
| `profile.resume(co, ...)` | タイミング付きの coroutine.resume |
| `profile.wrap(f)` | タイミング付きのコルーチンラッパーを作成 |

```lua
profile.start()
-- 計算集約的な操作を実行
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## オリジナル skynet との差異

- デバッグプロトコルのコマンドセットはほぼ同一
- オリジナルには `signal` 機能（デッドループの Lua コードを中断）があるが、skynet-cpp は未実装
- オリジナルには `skynet.trace()` メッセージトレースログがあるが、skynet-cpp は未実装

