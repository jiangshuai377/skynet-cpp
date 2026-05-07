# CriticalSection
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> File de sérialisation des messages de skynet-cpp

---

```lua
local queue = require "skynet.queue"
```

Au sein d'un même service skynet-cpp, si une API bloquante (comme `skynet.call`) est appelée durant le traitement d'un message, le service sera suspendu. Pendant la suspension, ce service peut répondre à d'autres messages. Cela peut facilement causer des problèmes d'ordonnancement qu'il faut traiter avec beaucoup de précaution.

Autrement dit, dès que votre traitement de message fait appel à une requête externe, le message arrivé en premier n'est pas nécessairement traité avant celui arrivé après. Après chaque appel bloquant, l'état interne du service n'est pas nécessairement le même qu'avant l'appel.

Le module `skynet.queue` peut vous aider à éviter la complexité engendrée par cette pseudo-concurrence.

---

## Méthode d'utilisation

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs est une file d'exécution

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 entre en section critique
end

function CMD.foo()
    cs(func2)  -- func2 entre en section critique
end
```

Si vous utilisez la file `cs`, alors `func1` et `func2` ne pourront pas être interrompues mutuellement durant leur exécution.

Si le service reçoit plusieurs messages `foobar` ou `foo`, chaque message sera entièrement traité avant le suivant, même si `func1` ou `func2` contiennent des appels bloquants comme `skynet.call`.

---

## Réentrance

Appeler cs à l'intérieur de func1 est parfaitement légal (pas de deadlock) :

```lua
local function func2()
    -- étape 3
end

local function func1()
    -- étape 2
    cs(func2)
    -- étape 4
end

function CMD.foobar()
    -- étape 1
    cs(func1)
    -- étape 5
end
```

À chaque réception d'un message foobar, le flux d'exécution suit l'ordre étape 1 → 2 → 3 → 4 → 5.

---

## Principe d'implémentation

La file implémente l'ordonnancement FIFO via les mécanismes suivants :

- `current_thread` : enregistre la coroutine détenant actuellement le verrou
- Compteur de références `ref` : supporte les appels imbriqués de la même coroutine (réentrance)
- File d'attente `thread_queue` : les nouvelles requêtes sont ajoutées en fin de file
- Utilise `skynet.wait()` / `skynet.wakeup()` pour la suspension et le réveil entre coroutines

---

## Différences avec le skynet original

- API entièrement identiques
- Implémentation identique (basée sur skynet.wait/wakeup)

