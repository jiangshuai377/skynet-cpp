# ShareData
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp 共有データ

---

```lua
local sharedata = require "sharedata"
```

ビジネスロジックを複数のサービスに分割した後、データの共有方法は最もよく直面する問題です。sharedata モジュールは、同一プロセス内の複数のサービス間で読み取り専用の構造化データを共有するために使用されます。典型的な用途は設定テーブルの配布です。

---

## 使い方

### データプロバイダ

```lua
-- 共有データの作成
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- データの更新
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- データの削除
sharedata.delete("game_config")
```

### データコンシューマ

```lua
-- データの照会（初回照会時に monitor コルーチンが起動し、更新を監視）
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- データ更新後、次回アクセス時に自動的に新バージョンを取得
-- ディープコピーの取得（一度きりの使用に適しており、より効率的）
local copy = sharedata.deepcopy("game_config")
```

---

## API

| 関数 | 説明 |
|---|---|
| `sharedata.new(name, value)` | 共有データを作成。value は任意の Lua table |
| `sharedata.query(name)` | 共有データを照会。初回照会時に monitor コルーチンを起動し、自動的に更新を追跡 |
| `sharedata.update(name, value)` | 共有データを更新。すべての保有者の monitor に通知 |
| `sharedata.delete(name)` | 共有データを削除 |
| `sharedata.flush()` | ローカルキャッシュをクリア。次回 query 時にサーバーから再取得 |
| `sharedata.deepcopy(name, ...)` | データのディープコピーを取得。追加パラメータはサブテーブルへのキーチェーンインデックス |

---

## 実装アーキテクチャ

```
sharedatad (唯一サービス)                   sharedata クライアント (各使用者)
├─ data_store[name]                    ├─ local_cache[name]
│   ├─ data (Lua table)                │   ├─ data
│   └─ version (インクリメンタル整数)  │   └─ version
└─ コマンド:                           └─ monitor コルーチン:
    new/delete/query/update/monitor       sharedatad へのロングポーリングでバージョン変更を待つ
```

**データフロー**：
1. サービス A が `sharedata.new("cfg", data)` を呼び出す → sharedatad がデータを保存
2. サービス B が `sharedata.query("cfg")` を呼び出す → sharedatad からデータを取得 + monitor を起動
3. サービス A が `sharedata.update("cfg", new_data)` を呼び出す → sharedatad が更新 + すべての monitor に通知
4. サービス B の monitor が通知を受信 → ローカルキャッシュを自動更新

---

## オリジナル skynet との差異

- オリジナルの sharedata は C 共有メモリを使用し、複数の Lua VM が同一のメモリブロックを直接読み取る。skynet-cpp はメッセージパッシングによるディープコピーでデータを渡し、機能は等価だがメモリを共有しない
- オリジナルには `sharetable` モジュール（`lua_clonefunction` ベース）があるが、skynet-cpp は非対応
- オリジナルの query で取得したオブジェクトは通常の table のように読み取れる（`__index` メタメソッド経由）が、skynet-cpp は通常の table を直接返す
- オリジナルには STM / ShareMap モジュールがあるが、skynet-cpp は非対応

