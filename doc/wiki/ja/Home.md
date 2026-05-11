# skynet-cpp Wiki
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> **skynet-cpp** — モダン C++20 で再実装された [Skynet](https://github.com/cloudwu/skynet) Actor フレームワーク

---

## ようこそ

skynet-cpp は軽量な Actor モデルサーバーフレームワークです。その設計理念と API セマンティクスは [cloudwu/skynet](https://github.com/cloudwu/skynet) に由来しています。フレームワークは skynet のコア抽象——**各サービスは独立した Actor であり、非同期メッセージ通信を行う**——を維持しつつ、モダン C++ の言語機能とクロスプラットフォームエコシステムにより、型安全性、RAII リソース管理、プラットフォーム非依存性を実現しています。

skynet-cpp についてまったく知識がない場合は、まず [GettingStarted](GettingStarted.md) をお読みください。skynet-cpp 自体はそれほど複雑ではないため、ソースコードも併せて読むことをおすすめします。

skynet-cpp の [Build](Build.md) は非常に簡単です。実際にコンパイルして試してみるのが良いスタートです。自分で二次開発を行いたい場合は、[Bootstrap](Bootstrap.md) の理解から始めてください。

skynet-cpp のコアは C++ で書かれていますが、単純な利用であれば C++ の基礎知識は不要です。Actor パターンの動作方式を理解し、ビジネスロジックを複数のサービスに分割して協調動作させる必要があります。Lua が必要な開発言語であり、Lua を理解していれば [LuaAPI](LuaAPI.md) を使用してサービス間の通信・協調を行えます。サービス間のデータ共有については、メッセージパッシング方式のほか、[ShareData](ShareData.md) も参照できます。

クライアントにサービスを提供するには、[Socket](Socket.md) API を使用するか、すでに実装されている [GateServer](GateServer.md) テンプレートで大量のクライアント接続を処理できます。[SocketChannel](SocketChannel.md) を使用すれば、skynet-cpp で外部 socket イベントを非同期にスケジューリングできます。データベースなどの[外部サービス](ExternalService.md)へのアクセスは、SocketChannel でラップすることを推奨します。

skynet-cpp が提供する機能については [APIList](APIList.md) を参照してください。

---

## ドキュメント索引

### 入門

| ドキュメント | 説明 |
|---|---|
| [GettingStarted](GettingStarted.md) | フレームワーク概念、Actor モデル、メッセージ機構、クイックスタート |
| [Build](Build.md) | ビルド手順（CMake + MSVC/GCC/Clang） |
| [Bootstrap](Bootstrap.md) | 起動フロー：main.cpp → ActorSystem → preload |

### コア API

| ドキュメント | 説明 |
|---|---|
| [LuaAPI](LuaAPI.md) | skynet.lua 完全 API リファレンス |
| [Socket](Socket.md) | TCP/UDP Socket API |
| [GateServer](GateServer.md) | TCP ゲートウェイテンプレート + netpack パケット分割 |
| [SocketChannel](SocketChannel.md) | TCP 接続多重化 |

### クラスタと分散

| ドキュメント | 説明 |
|---|---|
| [Cluster](Cluster.md) | ノード間 RPC クラスタ |

### データとサービス間通信

| ドキュメント | 説明 |
|---|---|
| [ShareData](ShareData.md) | 共有読み取り専用データ |
| [CriticalSection](CriticalSection.md) | メッセージシリアライゼーションキュー（擬似並行の回避） |
| [Multicast](Multicast.md) | パブリッシュ/サブスクライブメッセージ |

### デバッグとツール

| ドキュメント | 説明 |
|---|---|
| [DebugConsole](DebugConsole.md) | デバッグコンソール + デバッグプロトコル |
| [CodeCache](CodeCache.md) | Lua 5.5 コードキャッシュ機構 |

### 外部サービス

| ドキュメント | 説明 |
|---|---|
| [ExternalService](ExternalService.md) | Redis / MySQL / MongoDB ドライバ |

### リファレンス

| ドキュメント | 説明 |
|---|---|
| [APIList](APIList.md) | 全モジュール API クイックリファレンス |

---

## オリジナル skynet との主な差異

| 項目 | オリジナル Skynet (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **言語** | 純 C 実装 | C++20（RAII + `std::shared_ptr`） |
| **プラットフォーム** | Linux のみ（epoll） | クロスプラットフォーム（Asio：Windows/Linux/macOS）|
| **型安全性** | `void*` メッセージ | `std::any` + `msg.get<T>()` |
| **並行プリミティブ** | 自製 spinlock | `moodycamel::ConcurrentQueue` ロックフリーキュー |
| **非同期 IO** | 自製 socket server | Asio + `steady_timer` |
| **Lua バージョン** | Lua 5.4 | Lua 5.5.0（codecache 含む） |
| **ビルドシステム** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **harbor モード** | master/slave 対応 | 非対応（cluster モードのみ） |
| **Snax** | 対応 | 非対応 |
| **Sproto** | 対応 | 非対応 |
| **DataCenter** | 対応 | 非対応（廃止済み） |
| **ShareData** | C 共有メモリ | メッセージパッシングによるディープコピー（機能等価） |
| **データベースドライバ** | C モジュール含む | 純 Lua 実装（BSON/SHA1 ともに純 Lua） |

