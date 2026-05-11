# APIList
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp 全モジュール API クイックリファレンス

---

## skynet ([LuaAPI](LuaAPI.md))

### サービス構築

| API | 説明 |
|---|---|
| `skynet.register_protocol(class)` | メッセージ処理機構の登録 |
| `skynet.start(func)` | サービスの初期化とコールバック登録 |
| `skynet.dispatch(type, func)` | メッセージ処理関数の設定 |
| `skynet.getenv(key)` | 環境変数の読み取り |
| `skynet.setenv(key, value)` | 環境変数の設定 |

### フレームワーク構築

| API | 説明 |
|---|---|
| `skynet.newservice(name, ...)` | 新しい Lua サービスの起動 |
| `skynet.uniqueservice(name, ...)` | ユニークサービスの起動 |
| `skynet.queryservice(name)` | ユニークサービスアドレスの照会 |
| `skynet.localname(name)` | ローカル名の照会 |
| `skynet.appendpath(path)` | Append a Lua module directory |
| `skynet.prependpath(path)` | Prepend a Lua module directory |
| `skynet.appendcpath(path)` | Append a C module directory with platform `.dll` / `.so` expansion |
| `skynet.appendservicepath(path)` | Append a service search directory |
| `skynet.getpath()` | Return the current global path snapshot |
| `skynet.getcwd()` | Return the process current working directory |
| `skynet.setpathbase(path)` | Set the relative path resolution base |
| `skynet.getpathbase()` | Return the current pathbase |
| `skynet.readfile(path)` | Resolve from pathbase and read a file |
| `skynet.writefile(path, data, append)` | Resolve from pathbase and write a file |
| `skynet.systemstat()` | Return process-level runtime statistics |

### タスクスケジューリング

| API | 説明 |
|---|---|
| `skynet.sleep(ti)` | ti センチ秒サスペンド |
| `skynet.yield()` | CPU を明け渡す |
| `skynet.wait(token)` | 覚醒を待機 |
| `skynet.wakeup(token)` | コルーチンを覚醒 |
| `skynet.fork(func, ...)` | 新しいコルーチンを起動 |
| `skynet.timeout(ti, func)` | タイマー実行 |
| `skynet.now()` | プロセス起動後の経過センチ秒 |
| `skynet.starttime()` | プロセス起動時 UTC 時刻 |
| `skynet.time()` | 現在の UTC 時刻（秒） |
| `skynet.self()` | 現在のサービスアドレス |
| `skynet.address(addr)` | アドレス文字列のフォーマット |
| `skynet.exit()` | 現在のサービスを終了 |

### メッセージパッシング

| API | 説明 |
|---|---|
| `skynet.send(addr, type, ...)` | 非同期送信 |
| `skynet.call(addr, type, ...)` | 同期 RPC 呼び出し |
| `skynet.rawsend(addr, type, msg, sz)` | 生の送信 |
| `skynet.rawcall(addr, type, msg, sz)` | 生の RPC |
| `skynet.ret(msg, sz)` | メッセージ応答 |
| `skynet.retpack(...)` | パックして応答 |
| `skynet.response([pack])` | 遅延応答クロージャ |
| `skynet.redirect(addr, src, type, session, ...)` | 偽装送信 |
| `skynet.error(...)` | ログ送信 |
| `skynet.pack(...)` | シリアライズ |
| `skynet.unpack(msg, sz)` | デシリアライズ |
| `skynet.packstring(...)` | string にシリアライズ |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | lightuserdata を解放 |

### 管理

| API | 説明 |
|---|---|
| `skynet.register(name)` | サービス名の登録 |
| `skynet.name(name, addr)` | アドレスに名前を登録 |
| `skynet.kill(addr)` | サービスを強制終了 |
| `skynet.harbor(addr)` | 常に 0 を返す |
| `skynet.genid()` | ユニーク session を生成 |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | 説明 |
|---|---|
| `cluster.call(node, addr, ...)` | リモート RPC 呼び出し |
| `cluster.send(node, addr, ...)` | リモート非同期プッシュ |
| `cluster.open(addr, port)` | クラスタ監視を開始 |
| `cluster.reload(cfg)` | クラスタ設定を再ロード |
| `cluster.register(name, addr)` | 名前を登録 |
| `cluster.unregister(name)` | 名前を解除 |
| `cluster.query(node, name)` | リモート名を照会 |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | 説明 |
|---|---|
| `queue()` | 実行キューの作成 |
| `cs(func, ...)` | キュー内でシリアル実行 |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | 説明 |
|---|---|
| `sharedata.new(name, value)` | 共有データの作成 |
| `sharedata.query(name)` | 共有データの照会 |
| `sharedata.update(name, value)` | 共有データの更新 |
| `sharedata.delete(name)` | 共有データの削除 |
| `sharedata.flush()` | ローカルキャッシュのクリア |
| `sharedata.deepcopy(name, ...)` | ディープコピー |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | 説明 |
|---|---|
| `multicast.new(opts)` | チャンネル作成 |
| `mc:subscribe()` | サブスクライブ |
| `mc:unsubscribe()` | サブスクライブ解除 |
| `mc:publish(...)` | メッセージ発行 |
| `mc:delete()` | チャンネル削除 |

---

## skynet.socket ([Socket](Socket.md))

| API | 説明 |
|---|---|
| `socket.listen(host, port, handler)` | TCP ポートの監視 |
| `socket.ondata(id, handler)` | データコールバックの設定 |
| `socket.connect(host, port)` | TCP 接続 |
| `socket.send(id, data)` | データ送信 |
| `socket.write(lid, cid, data)` | listener 経由で送信 |
| `socket.read(id, sz)` | データ読み取り |
| `socket.readline(id, sep)` | デリミタで読み取り |
| `socket.readall(id)` | 全データ読み取り |
| `socket.close(id)` | 接続クローズ |
| `socket.close_listener(id)` | 監視クローズ |
| `socket.pause(lid, cid)` | 読み取り一時停止 |
| `socket.resume(lid, cid)` | 読み取り再開 |
| `socket.udp(host, port, cb)` | UDP 作成 |
| `socket.udp_send(id, data, host, port)` | UDP 送信 |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | 説明 |
|---|---|
| `socketchannel.channel(desc)` | channel の作成 |
| `channel:request(req, resp/session)` | リクエスト送信しレスポンスを待機 |
| `channel:response(func)` | レスポンスの受信のみ |
| `channel:connect(once)` | 明示的接続 |
| `channel:close()` | channel のクローズ |
| `channel:changehost(host, port)` | アドレスの変更 |
| `channel:read(sz)` | バイト読み取り |
| `channel:readline(sep)` | デリミタで読み取り |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱動))

| API | 説明 |
|---|---|
| `redis.connect(conf)` | Redis 接続 |
| `redis.watch(conf)` | pub/sub 監視の作成 |
| `db:*(...)` | 任意の Redis コマンド |
| `db:pipeline(ops)` | バッチ実行 |
| `db:disconnect()` | 切断 |
| `watch:subscribe(...)` | チャンネルのサブスクライブ |
| `watch:message()` | メッセージ受信 |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱動))

| API | 説明 |
|---|---|
| `mysql.connect(conf)` | MySQL 接続 |
| `db:query(sql)` | クエリ実行 |
| `db:prepare(sql)` | プリペアドステートメント |
| `stmt:execute()` | プリペアド実行 |
| `stmt:close()` | ステートメントクローズ |
| `db:disconnect()` | 切断 |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱動))

| API | 説明 |
|---|---|
| `mongo.client(conf)` | MongoDB 接続 |
| `client:getDB(name)` | データベース取得 |
| `db:getCollection(name)` | コレクション取得 |
| `db:runCommand(...)` | コマンド実行 |
| `coll:insert(doc)` | 挿入 |
| `coll:find(query, proj)` | クエリ |
| `coll:findOne(query, proj)` | 単一クエリ |
| `coll:update(q, u, upsert, multi)` | 更新 |
| `coll:delete(query, single)` | 削除 |
| `coll:count(query)` | カウント |
| `coll:aggregate(pipeline)` | 集約 |
| `coll:createIndex(keys, opts)` | インデックス作成 |
| `coll:drop()` | コレクション削除 |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | カーソル操作 |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | 説明 |
|---|---|
| `bson.encode(doc)` | BSON エンコード |
| `bson.encode_order(k1, v1, ...)` | 順序保持エンコード |
| `bson.decode(data)` | BSON デコード |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | 64 ビット整数 |
| `bson.null` | null 定数 |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | 説明 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 ハッシュ |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 エンコード |
| `crypt.base64decode(data)` | Base64 デコード |
| `crypt.hexencode(data)` | Hex エンコード |
| `crypt.hexdecode(data)` | Hex デコード |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | 説明 |
|---|---|
| `profile.start([co])` | タイミング開始 |
| `profile.stop([co])` | タイミング停止 |
| `profile.resume(co, ...)` | タイミング付き resume |
| `profile.wrap(f)` | タイミングラッパーの作成 |


