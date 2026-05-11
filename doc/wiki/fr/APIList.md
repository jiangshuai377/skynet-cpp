# APIList
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Tableau de référence rapide des API de tous les modules skynet-cpp

---

## skynet ([LuaAPI](LuaAPI.md))

### Construction de service

| API | Description |
|---|---|
| `skynet.register_protocol(class)` | Enregistre un mécanisme de traitement des messages |
| `skynet.start(func)` | Initialise le service et enregistre le callback |
| `skynet.dispatch(type, func)` | Définit la fonction de traitement des messages |
| `skynet.getenv(key)` | Lit une variable d'environnement |
| `skynet.setenv(key, value)` | Définit une variable d'environnement |

### Construction de framework

| API | Description |
|---|---|
| `skynet.newservice(name, ...)` | Démarre un nouveau service Lua |
| `skynet.uniqueservice(name, ...)` | Démarre un service unique |
| `skynet.queryservice(name)` | Recherche l'adresse d'un service unique |
| `skynet.localname(name)` | Recherche un nom local |
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

### Ordonnancement des tâches

| API | Description |
|---|---|
| `skynet.sleep(ti)` | Suspend pendant ti centisecondes |
| `skynet.yield()` | Cède le CPU |
| `skynet.wait(token)` | Attend un réveil |
| `skynet.wakeup(token)` | Réveille une coroutine |
| `skynet.fork(func, ...)` | Lance une nouvelle coroutine |
| `skynet.timeout(ti, func)` | Exécution différée |
| `skynet.now()` | Centisecondes écoulées depuis le démarrage du processus |
| `skynet.starttime()` | Heure UTC de démarrage du processus |
| `skynet.time()` | Heure UTC actuelle (secondes) |
| `skynet.self()` | Adresse du service courant |
| `skynet.address(addr)` | Formate l'adresse en chaîne |
| `skynet.exit()` | Quitte le service courant |

### Passage de messages

| API | Description |
|---|---|
| `skynet.send(addr, type, ...)` | Envoi asynchrone |
| `skynet.call(addr, type, ...)` | Appel RPC synchrone |
| `skynet.rawsend(addr, type, msg, sz)` | Envoi brut |
| `skynet.rawcall(addr, type, msg, sz)` | RPC brut |
| `skynet.ret(msg, sz)` | Réponse au message |
| `skynet.retpack(...)` | Empaquette et répond |
| `skynet.response([pack])` | Fermeture de réponse différée |
| `skynet.redirect(addr, src, type, session, ...)` | Envoi déguisé |
| `skynet.error(...)` | Envoi de journal |
| `skynet.pack(...)` | Sérialisation |
| `skynet.unpack(msg, sz)` | Désérialisation |
| `skynet.packstring(...)` | Sérialisation en string |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | Libère lightuserdata |

### Gestion

| API | Description |
|---|---|
| `skynet.register(name)` | Enregistre un nom de service |
| `skynet.name(name, addr)` | Enregistre un nom pour une adresse |
| `skynet.kill(addr)` | Termine un service de force |
| `skynet.harbor(addr)` | Retourne toujours 0 |
| `skynet.genid()` | Génère un session unique |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | Description |
|---|---|
| `cluster.call(node, addr, ...)` | Appel RPC distant |
| `cluster.send(node, addr, ...)` | Envoi asynchrone distant |
| `cluster.open(addr, port)` | Ouvre l'écoute cluster |
| `cluster.reload(cfg)` | Recharge la configuration cluster |
| `cluster.register(name, addr)` | Enregistre un nom |
| `cluster.unregister(name)` | Dés-enregistre un nom |
| `cluster.query(node, name)` | Recherche un nom distant |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | Description |
|---|---|
| `queue()` | Crée une file d'exécution |
| `cs(func, ...)` | Exécution sérialisée dans la file |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | Description |
|---|---|
| `sharedata.new(name, value)` | Crée des données partagées |
| `sharedata.query(name)` | Interroge les données partagées |
| `sharedata.update(name, value)` | Met à jour les données partagées |
| `sharedata.delete(name)` | Supprime les données partagées |
| `sharedata.flush()` | Vide le cache local |
| `sharedata.deepcopy(name, ...)` | Copie profonde |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | Description |
|---|---|
| `multicast.new(opts)` | Crée un canal |
| `mc:subscribe()` | S'abonne |
| `mc:unsubscribe()` | Se désabonne |
| `mc:publish(...)` | Publie un message |
| `mc:delete()` | Supprime le canal |

---

## skynet.socket ([Socket](Socket.md))

| API | Description |
|---|---|
| `socket.listen(host, port, handler)` | Écoute un port TCP |
| `socket.ondata(id, handler)` | Définit le callback de données |
| `socket.connect(host, port)` | Connexion TCP |
| `socket.send(id, data)` | Envoie des données |
| `socket.write(lid, cid, data)` | Envoie via le listener |
| `socket.read(id, sz)` | Lit des données |
| `socket.readline(id, sep)` | Lit par séparateur |
| `socket.readall(id)` | Lit tout |
| `socket.close(id)` | Ferme la connexion |
| `socket.close_listener(id)` | Ferme l'écoute |
| `socket.pause(lid, cid)` | Met en pause la lecture |
| `socket.resume(lid, cid)` | Reprend la lecture |
| `socket.udp(host, port, cb)` | Crée un UDP |
| `socket.udp_send(id, data, host, port)` | Envoie un UDP |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | Description |
|---|---|
| `socketchannel.channel(desc)` | Crée un channel |
| `channel:request(req, resp/session)` | Envoie une requête et attend la réponse |
| `channel:response(func)` | Reçoit uniquement une réponse |
| `channel:connect(once)` | Connexion explicite |
| `channel:close()` | Ferme le channel |
| `channel:changehost(host, port)` | Change l'adresse |
| `channel:read(sz)` | Lit des octets |
| `channel:readline(sep)` | Lit par séparateur |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱动))

| API | Description |
|---|---|
| `redis.connect(conf)` | Connexion à Redis |
| `redis.watch(conf)` | Crée un écouteur pub/sub |
| `db:*(...)` | Toute commande Redis |
| `db:pipeline(ops)` | Exécution par lot |
| `db:disconnect()` | Déconnexion |
| `watch:subscribe(...)` | Abonnement aux canaux |
| `watch:message()` | Réception de message |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱动))

| API | Description |
|---|---|
| `mysql.connect(conf)` | Connexion à MySQL |
| `db:query(sql)` | Exécution de requête |
| `db:prepare(sql)` | Instruction préparée |
| `stmt:execute()` | Exécution de l'instruction préparée |
| `stmt:close()` | Fermeture de l'instruction |
| `db:disconnect()` | Déconnexion |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Description |
|---|---|
| `mongo.client(conf)` | Connexion à MongoDB |
| `client:getDB(name)` | Obtient une base de données |
| `db:getCollection(name)` | Obtient une collection |
| `db:runCommand(...)` | Exécute une commande |
| `coll:insert(doc)` | Insertion |
| `coll:find(query, proj)` | Requête |
| `coll:findOne(query, proj)` | Requête d'un seul document |
| `coll:update(q, u, upsert, multi)` | Mise à jour |
| `coll:delete(query, single)` | Suppression |
| `coll:count(query)` | Comptage |
| `coll:aggregate(pipeline)` | Agrégation |
| `coll:createIndex(keys, opts)` | Création d'index |
| `coll:drop()` | Suppression de collection |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | Opérations sur curseur |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Description |
|---|---|
| `bson.encode(doc)` | Encode en BSON |
| `bson.encode_order(k1, v1, ...)` | Encodage avec ordre préservé |
| `bson.decode(data)` | Décode du BSON |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | Entier 64 bits |
| `bson.null` | Constante null |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | Description |
|---|---|
| `crypt.sha1(msg)` | Hachage SHA-1 |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Encodage Base64 |
| `crypt.base64decode(data)` | Décodage Base64 |
| `crypt.hexencode(data)` | Encodage Hex |
| `crypt.hexdecode(data)` | Décodage Hex |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | Description |
|---|---|
| `profile.start([co])` | Commence le chronométrage |
| `profile.stop([co])` | Arrête le chronométrage |
| `profile.resume(co, ...)` | Resume avec chronométrage |
| `profile.wrap(f)` | Crée un wrapper avec chronométrage |


