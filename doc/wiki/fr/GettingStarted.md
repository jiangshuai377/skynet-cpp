# GettingStarted
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Guide de démarrage de skynet-cpp

---

## Framework

skynet-cpp est un framework serveur léger basé sur le modèle Actor. Vous pouvez le considérer comme un système d'exploitation simple capable d'ordonnancer des milliers de machines virtuelles Lua pour qu'elles travaillent en parallèle. Chaque machine virtuelle Lua peut recevoir et traiter les messages envoyés par d'autres machines virtuelles, ainsi qu'envoyer des messages à d'autres machines virtuelles.

skynet-cpp intègre la gestion des données réseau externes et des minuteries, et les convertit en messages uniformes transmis aux différents services.

### Relation avec le skynet original

La philosophie de conception et la sémantique des API de skynet-cpp proviennent entièrement de [cloudwu/skynet](https://github.com/cloudwu/skynet), mais le framework sous-jacent a été réimplémenté en C++20. Pour les développeurs Lua, l'utilisation des API est essentiellement identique à celle du skynet original.

---

## Service (Service)

Les services de skynet-cpp sont écrits en Lua. Il suffit de placer les fichiers `.lua` conformes aux conventions dans un chemin accessible par skynet-cpp pour qu'ils puissent être démarrés par d'autres services. Chaque service possède une adresse 32 bits unique (handle), attribuée par le framework.

Chaque service passe par trois phases d'exécution :

1. **Phase de chargement** : Le fichier source du service est chargé et exécuté. Durant cette phase, il est **interdit** d'appeler toute API bloquante.
2. **Phase d'initialisation** : La fonction d'initialisation enregistrée via `skynet.start(func)` est exécutée. Durant cette phase, toute API skynet peut être appelée. Le `skynet.newservice` qui a démarré ce service attend la fin de l'initialisation.
3. **Phase de travail** : Une fois l'initialisation terminée, le service ayant enregistré des fonctions de traitement de messages commence à répondre aux messages.

```lua
local skynet = require "skynet"

-- Phase de chargement : définir les variables au niveau du module
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- Phase d'initialisation : enregistrer la distribution des messages
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## Message (Message)

Chaque message skynet-cpp est constitué des éléments suivants :

1. **session** : Un identifiant unique généré par le service initiateur de la requête. Le répondeur renvoie le session dans sa réponse, permettant à l'émetteur de faire correspondre requête et réponse. Un session à 0 signifie qu'aucune réponse n'est attendue (envoi unidirectionnel).
2. **source** : L'adresse du service source du message (handle 32 bits).
3. **type** : La catégorie du message. Le plus couramment utilisé est `"lua"`, pour la communication entre services Lua.
4. **message + size** : Le contenu du message (pointeur C + longueur), généré par la fonction de sérialisation.

### Types de messages

| Type | Nom | Usage |
|---|---|---|
| 0 | `text` | Message texte brut |
| 1 | `response` | Réponse RPC |
| 6 | `socket` | Événement réseau |
| 7 | `error` | Notification d'erreur |
| 10 | `lua` | Message sérialisé Lua (le plus courant) |

---

## Ordonnancement des coroutines

Du point de vue bas niveau, chaque service est un processeur de messages. Mais au niveau applicatif, il fonctionne grâce aux coroutines de Lua.

Lorsque votre service envoie une requête à un autre service (`skynet.call`), la coroutine courante est suspendue. Lorsque l'autre partie reçoit la requête et y répond, le framework retrouve la coroutine suspendue, lui transmet les informations de réponse et poursuit le processus métier interrompu. Du point de vue de l'utilisateur, c'est comme si un thread indépendant traitait la logique métier.

**Attention à la réentrance** : Lorsqu'un service est suspendu dans un processus métier, il peut toujours traiter d'autres messages. Ainsi, l'état interne du service obtenu avant un `skynet.call` peut avoir changé au moment du retour. L'exécution entre deux appels d'API bloquants est atomique. Vous pouvez utiliser [CriticalSection](CriticalSection.md) pour réduire la complexité liée à la pseudo-concurrence.

---

## Réseau

skynet-cpp intègre une couche réseau encapsulant les fonctionnalités TCP et UDP. Il est déconseillé d'utiliser dans les services tout module interagissant directement avec les API réseau du système, car un blocage par les IO réseau affecterait l'ensemble du thread de travail.

L'utilisation de l'API [Socket](Socket.md) intégrée de skynet-cpp permet de libérer complètement la capacité de traitement CPU lors d'un blocage réseau.

Il est recommandé d'utiliser le service de passerelle [GateServer](GateServer.md) pour gérer les connexions client.

---

## Services externes

skynet-cpp fournit des modules pilotes pour [Redis](ExternalService.md#redis-驱动), [MySQL](ExternalService.md#mysql-驱动) et [MongoDB](ExternalService.md#mongodb-驱动). Ces modules pilotes sont tous basés sur [SocketChannel](SocketChannel.md) et s'intègrent parfaitement avec skynet-cpp.

---

## Cluster

skynet-cpp implémente le mode cluster pour supporter le RPC inter-nœuds. Voir [Cluster](Cluster.md) pour plus de détails.

Contrairement au skynet original, skynet-cpp **ne supporte pas** le mode master/slave (mode harbor). Il est recommandé d'utiliser exclusivement le mode cluster.

---

## Différences avec le skynet original

- **Non supporté** : mode master/slave (harbor)
- **Non supporté** : framework Snax
- **Non supporté** : protocole Sproto
- **Non supporté** : DataCenter (abandonné)
- ShareData utilise la copie profonde par passage de messages, et non la mémoire partagée C
- Utilise Lua 5.5.0 (l'original utilise Lua 5.4)
- Les pilotes de base de données (BSON/SHA1) sont entièrement implémentés en Lua pur

