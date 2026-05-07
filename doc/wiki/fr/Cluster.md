# Cluster
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Cluster skynet-cpp

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp implémente le mode cluster pour supporter le RPC inter-nœuds. Chaque nœud est un processus skynet-cpp indépendant, et les nœuds communiquent par passage de messages via des connexions TCP.

---

## Démarrage rapide

### Nœud A : Écoute + fourniture de service

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- Enregistrer un nom pour l'accès distant
    cluster.register("echo", echo)

    -- Charger la configuration du cluster
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Ouvrir le port d'écoute
    cluster.open("127.0.0.1", 19999)
end)
```

### Nœud B : Appel distant

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Appel RPC au service echo du nœud A
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- Requête de nom enregistré
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| Fonction | Description |
|---|---|
| `cluster.call(node, addr, ...)` | Appel RPC synchrone vers un service d'un nœud distant. Bloque en attendant la réponse |
| `cluster.send(node, addr, ...)` | Envoi asynchrone de message vers un nœud distant (sans réponse). Risque de perte |
| `cluster.open(addr, port)` | Ouvre un port d'écoute pour accepter les connexions cluster entrantes |
| `cluster.reload(cfg)` | Recharge la configuration du cluster. cfg est une table `{nodename = "host:port", ...}` |
| `cluster.register(name, addr)` | Enregistre un nom de service local accessible à distance via `@name`. addr par défaut est le service courant |
| `cluster.unregister(name)` | Dés-enregistre un nom enregistré |
| `cluster.query(node, name)` | Recherche l'adresse d'un service enregistré via `cluster.register` sur un nœud distant |

### Format d'adresse

Le deuxième paramètre `addr` de `cluster.call` peut être :

- **Nom sous forme de chaîne** : comme `".echo"`, recherche ce nom sur le nœud cible
- **Nom préfixé par `@`** : comme `"@echo"`, recherche via les noms enregistrés par `cluster.register`
- **Adresse numérique** : si vous connaissez déjà le handle du service distant

---

## Architecture

Le système cluster est composé de trois services :

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ service local
  (gestionnaire) (sortant)         (entrant)          ↓
      ▲                                           réponse
      │                                              │
      └────────────────────── [TCP] ←─────────────────┘
```

| Service | Nombre | Responsabilité |
|---|---|---|
| `clusterd` | 1 par nœud | Gestionnaire central : configuration, cycle de vie sender/agent, enregistrement des noms, écoute |
| `clustersender` | 1 par nœud distant | Maintient la connexion TCP vers le nœud distant, envoie les requêtes via socketchannel |
| `clusteragent` | 1 par connexion | Traite les connexions entrantes, analyse les requêtes et les transmet aux services locaux, renvoie les réponses |

---

## Protocole cluster

Le module C `cluster.core` implémente le protocole filaire du cluster :

- **Format de paquet** : en-tête de longueur 2 octets big-endian + charge utile
- **Paquet de requête** : marqueur de type + session + adresse cible + message sérialisé
- **Paquet de réponse** : session + succès/échec + message sérialisé
- **Fragmentation des gros messages** : les messages dépassant 32 Ko sont automatiquement découpés en plusieurs segments pour la transmission

---

## Ordre des messages

La plupart des requêtes entre clusters sont ordonnées selon l'ordre d'appel (premier envoyé, premier arrivé). Cependant, lorsqu'un paquet dépasse 32 Ko, il est fragmenté pour la transmission, et les gros paquets peuvent arriver après les petits.

Les requêtes et les réponses utilisent la même connexion TCP, l'ordre est garanti.

---

## Mise à jour de la configuration

La configuration est rechargée via `cluster.reload(cfg)`. Si l'adresse d'un nœud est modifiée, les nouvelles requêtes après le reload seront envoyées à la nouvelle adresse. Les requêtes non terminées restent en attente sur l'ancienne adresse.

L'adresse d'un nœud peut être définie à `false` pour le marquer comme hors ligne.

---

## Différences avec le skynet original

- skynet-cpp **ne supporte pas** le mode master/slave (harbor), uniquement le mode cluster
- La configuration cluster originale est chargée depuis un fichier, skynet-cpp la passe via `cluster.reload(table)`
- L'original a `cluster.proxy(node, addr)` pour créer un proxy local, non encore implémenté dans skynet-cpp
- L'original a `cluster.snax` pour le support des services Snax distants, skynet-cpp ne supporte pas Snax
- La configuration originale supporte `__nowaiting = true`, non encore implémenté dans skynet-cpp

