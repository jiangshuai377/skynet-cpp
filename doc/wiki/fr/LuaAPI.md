# LuaAPI
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Référence des API Lua de skynet

---

```lua
local skynet = require "skynet"
```

Chaque service skynet-cpp doit importer le module `skynet`. Ce module ne peut pas être utilisé en dehors du framework skynet-cpp.

---

## Adresse de service

Chaque service possède une adresse numérique 32 bits (handle).

- `skynet.self()` — Retourne l'adresse du service courant
- `skynet.address(addr)` — Convertit l'adresse en chaîne lisible (format `:xxxxxxxx`)
- `skynet.register(name)` — Enregistre un alias pour le service courant (préfixe `.` pour un nom local)
- `skynet.name(name, handle)` — Enregistre un alias pour le service du handle spécifié
- `skynet.localname(name)` — Recherche l'adresse correspondant à un nom local (non bloquant)

Tous les paramètres d'API acceptant une adresse de service peuvent recevoir un alias sous forme de chaîne.

---

## Distribution et réponse aux messages

### skynet.dispatch(type, func)

Enregistre la fonction de traitement pour une catégorie de messages spécifique. Utilisation la plus courante :

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

Enregistre une nouvelle catégorie de messages. class doit fournir les champs `name`, `id`, `pack`, `unpack`.

### skynet.ret(msg, sz)

Répond au message de la source de requête actuelle. Ne peut être appelé qu'une seule fois dans le même coroutine de traitement de message.

### skynet.retpack(...)

Raccourci pour `skynet.ret(skynet.pack(...))`.

### skynet.response([packfunc])

Génère une fermeture (closure) de réponse différée, qui peut être appelée ultérieurement dans une autre coroutine.

```lua
local resp = skynet.response()
-- Appelé plus tard ailleurs :
resp(true, result1, result2)   -- Réponse normale
resp(false)                     -- Lève une exception pour le demandeur
```

---

## Envoi de messages et appels distants

### skynet.send(addr, typename, ...)

Envoie un message de type typename à addr. API non bloquante, le message est empaqueté via la fonction pack.

### skynet.call(addr, typename, ...)

Envoie une requête à addr et attend la réponse de manière bloquante. La réponse est désérialisée via unpack avant d'être retournée. **Attention** : `skynet.call` ne bloque que la coroutine courante, le service peut toujours répondre à d'autres messages.

### skynet.rawsend(addr, typename, msg, sz)

Envoi brut, sans passer par l'empaquetage pack.

### skynet.rawcall(addr, typename, msg, sz)

Appel RPC brut, sans passer par pack/unpack.

### skynet.redirect(addr, source, typename, session, ...)

Envoie un message à addr en se faisant passer pour l'adresse source.

---

## Horloge et threads

La précision de l'horloge interne est de 1/100 de seconde (centisecondes).

- `skynet.now()` — Retourne le temps écoulé depuis le démarrage du processus (en centisecondes)
- `skynet.starttime()` — Retourne l'heure UTC de démarrage du processus (en secondes)
- `skynet.time()` — Retourne l'heure UTC actuelle (en secondes, précision de 10ms)

### skynet.sleep(ti)

Suspend la coroutine courante pendant ti centisecondes. Retourne `"BREAK"` si réveillée par `wakeup`.

### skynet.yield()

Équivalent à `skynet.sleep(0)`. Cède le contrôle du CPU.

### skynet.timeout(ti, func)

Exécute func dans une nouvelle coroutine après ti centisecondes. API non bloquante.

### skynet.fork(func, ...)

Lance une nouvelle coroutine pour exécuter func. Plus efficace que `timeout(0, ...)` (ne passe pas par la minuterie).

### skynet.wait(token)

Suspend la coroutine courante, en attendant un réveil par `wakeup`. Le token par défaut est `coroutine.running()`.

### skynet.wakeup(token)

Réveille une coroutine suspendue par `sleep` ou `wait`.

---

## Démarrage et arrêt des services

### skynet.start(func)

Enregistre la fonction de démarrage du service. **Doit être appelé**, c'est le point d'entrée du service.

### skynet.exit()

Quitte le service courant. Le code suivant ne sera pas exécuté, et les coroutines suspendues seront interrompues.

### skynet.newservice(name, ...)

Démarre un nouveau service Lua. API bloquante, attend que la fonction `start` du service démarré retourne avant de revenir.

### skynet.uniqueservice(name, ...)

Démarre un service unique. Si déjà démarré, retourne l'adresse existante.

### skynet.queryservice(name)

Recherche l'adresse d'un service unique. Attend si le service n'est pas encore démarré.

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

## Sérialisation

- `skynet.pack(...)` — Sérialise les valeurs Lua en `(lightuserdata, size)`
- `skynet.unpack(msg, sz)` — Désérialise en valeurs Lua
- `skynet.packstring(...)` — Sérialise en chaîne Lua
- `skynet.tostring(msg, sz)` — Convertit lightuserdata en chaîne Lua
- `skynet.trash(msg, sz)` — Libère le tampon lightuserdata

Types supportés : string, boolean, number, lightuserdata, table (sans métatable).

---

## Journalisation

### skynet.error(...)

Concatène les paramètres et les envoie au service logger. Format de sortie : `[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## Requête d'état

- `skynet.info_func(func)` — Enregistre une fonction de requête d'état interne, appelable via le protocole de débogage
- `skynet.stat(what)` — Interroge l'état interne du service : `"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## Divers

- `skynet.getenv(key)` — Lit une variable d'environnement
- `skynet.setenv(key, value)` — Définit une variable d'environnement (non écrasable)
- `skynet.genid()` — Génère un session unique
- `skynet.harbor(addr)` — Retourne toujours 0 (skynet-cpp ne supporte pas harbor)

---

## Différences avec le skynet original

- `skynet.harbor()` retourne toujours 0
- `skynet.forward_type` et `skynet.filter` non supportés (transfert avancé de messages)
- `skynet.memlimit` doit être appelé avant `start`
- Les variables d'environnement sont transmises via `ActorSystem` et non via un fichier de configuration


