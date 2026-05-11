# CodeCache
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> Lua 5.5 コードキャッシュ機構

---

## 概要

skynet-cpp は skynet 修正版 Lua 5.5.0 を使用しており、**codecache** 機構を含んでいます。この機構により、複数の Lua VM（つまり複数のサービス）がコンパイル済みの Lua 関数プロトタイプ（Proto）を共有でき、以下を実現します：

1. **メモリ節約**：同一スクリプトのバイトコードは 1 回のみコンパイル
2. **起動の高速化**：後続の VM が同一スクリプトをロードする際、再解析不要で直接再利用

---

## 動作原理

Lua サービスが `loadfile` でスクリプトをロードする際：

1. **初回ロード**：通常通りコンパイルし、コンパイル済みの関数プロトタイプをグローバルキャッシュに格納
2. **以降のロード**：キャッシュから関数プロトタイプを直接クローン、コンパイルステップをスキップ

主要な C API 拡張：
- `lua_clonefunction(L, proto)` — 共有プロトタイプから新しいクロージャを作成
- `lua_sharefunction(L, index)` — 関数プロトタイプを共有プールに追加

---

## skynet-cpp での使用

`loader.lua` では、codecache はデフォルトで無効化されています（`cache.mode("OFF")`）。その理由は：

- skynet-cpp の各 `LuaActor` は独立した `lua_State` を持ち、各 VM の `_ENV` は完全に分離されている
- codecache が有効な場合、複数の VM が同一のコンパイル済み Proto を共有するが、各 VM のグローバル環境（`_ENV`）は異なる。Proto 内で `require` などのグローバル関数を参照する場合、`_ENV` が誤った VM を指す問題が発生する
- codecache を無効にすると、各 VM が独立してスクリプトをコンパイルし、`_ENV` は正しい VM を指す

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- 共有キャッシュを無効化
```

---

## 手動制御

`_ENV` に依存しない純粋関数スクリプトを確認できる場合は、選択的にキャッシュを有効化できます：

```lua
local cache = require "cache"

-- 現在のモードを照会
local mode = cache.mode()

-- モードを設定：ON / OFF
cache.mode("ON")   -- 共有キャッシュを有効化
cache.mode("OFF")  -- 共有キャッシュを無効化
```

---

## オリジナル skynet との差異

- オリジナル skynet はデフォルトで codecache 有効、skynet-cpp はデフォルトで無効
- オリジナルは `require "skynet.codecache"` で制御インターフェースを取得、skynet-cpp は `require "cache"` で制御
- オリジナルには `codecache.clear()` でキャッシュクリアが可能、skynet-cpp は未サポート

