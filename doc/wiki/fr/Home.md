# Wiki skynet-cpp
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> **skynet-cpp** — Réimplémentation en C++20 moderne du framework Actor [Skynet](https://github.com/cloudwu/skynet)

---

## Bienvenue

skynet-cpp est un framework serveur léger basé sur le modèle Actor, dont la philosophie de conception et la sémantique des API proviennent de [cloudwu/skynet](https://github.com/cloudwu/skynet). Le framework conserve l'abstraction fondamentale de skynet — **chaque service est un Actor indépendant communiquant par messages asynchrones** — tout en tirant parti des fonctionnalités du C++ moderne et de l'écosystème multiplateforme pour offrir la sécurité de typage, la gestion des ressources par RAII et l'indépendance vis-à-vis de la plateforme.

Si vous ne connaissez pas du tout skynet-cpp, commencez par lire [GettingStarted](GettingStarted.md). Comme skynet-cpp n'est pas très complexe en soi, il est également recommandé de consulter le code source.

[Compiler](Build.md) skynet-cpp est très simple, et c'est un bon point de départ que de le compiler et de l'essayer. Si vous souhaitez effectuer du développement secondaire, vous pouvez commencer par comprendre le [Bootstrap](Bootstrap.md).

Bien que le cœur de skynet-cpp soit écrit en C++, une utilisation simple ne nécessite pas de connaissances en C++. Vous devez comprendre le fonctionnement du modèle Actor et découper votre logique métier en plusieurs services collaboratifs. Lua est le langage de développement nécessaire — il vous suffit de connaître Lua pour utiliser l'[API Lua](LuaAPI.md) afin d'orchestrer la communication entre services. Pour le partage de données entre services, en plus du passage de messages, vous pouvez consulter [ShareData](ShareData.md).

Pour fournir des services aux clients, vous devez utiliser l'API [Socket](Socket.md), ou bien utiliser le modèle [GateServer](GateServer.md) déjà implémenté pour gérer un grand nombre de connexions client. Grâce à [SocketChannel](SocketChannel.md), skynet-cpp peut ordonnancer de manière asynchrone les événements socket externes. L'accès aux [services externes](ExternalService.md) comme les bases de données est de préférence encapsulé via SocketChannel.

Les fonctionnalités déjà fournies par skynet-cpp sont consultables dans la [liste des API](APIList.md).

---

## Index de la documentation

### Premiers pas

| Document | Description |
|---|---|
| [GettingStarted](GettingStarted.md) | Concepts du framework, modèle Actor, mécanisme de messages, démarrage rapide |
| [Build](Build.md) | Étapes de compilation (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Processus de démarrage : main.cpp → ActorSystem → preload |

### API principales

| Document | Description |
|---|---|
| [LuaAPI](LuaAPI.md) | Référence complète de l'API skynet.lua |
| [Socket](Socket.md) | API Socket TCP/UDP |
| [GateServer](GateServer.md) | Modèle de passerelle TCP + découpage netpack |
| [SocketChannel](SocketChannel.md) | Multiplexage de connexions TCP |

### Cluster et distribué

| Document | Description |
|---|---|
| [Cluster](Cluster.md) | Cluster RPC inter-nœuds |

### Données et communication inter-services

| Document | Description |
|---|---|
| [ShareData](ShareData.md) | Données partagées en lecture seule |
| [CriticalSection](CriticalSection.md) | File de sérialisation des messages (éviter la pseudo-concurrence) |
| [Multicast](Multicast.md) | Messages publication/abonnement |

### Débogage et outils

| Document | Description |
|---|---|
| [DebugConsole](DebugConsole.md) | Console de débogage + protocole de débogage |
| [CodeCache](CodeCache.md) | Mécanisme de cache de code Lua 5.5 |

### Services externes

| Document | Description |
|---|---|
| [ExternalService](ExternalService.md) | Pilotes Redis / MySQL / MongoDB |

### Référence

| Document | Description |
|---|---|
| [APIList](APIList.md) | Tableau récapitulatif des API de tous les modules |

---

## Principales différences avec le skynet original

| Dimension | Skynet original (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Langage** | Implémentation en C pur | C++20 (RAII + `std::shared_ptr`) |
| **Plateforme** | Linux uniquement (epoll) | Multiplateforme (Asio : Windows/Linux/macOS) |
| **Sécurité de typage** | Messages `void*` | `std::any` + `msg.get<T>()` |
| **Primitives de concurrence** | Spinlock propriétaire | File sans verrou `moodycamel::ConcurrentQueue` |
| **IO asynchrone** | Serveur socket propriétaire | Asio + `steady_timer` |
| **Version Lua** | Lua 5.4 | Lua 5.5.0 (avec codecache) |
| **Système de build** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Mode harbor** | Support master/slave | Non supporté (mode cluster uniquement) |
| **Snax** | Supporté | Non supporté |
| **Sproto** | Supporté | Non supporté |
| **DataCenter** | Supporté | Non supporté (abandonné) |
| **ShareData** | Mémoire partagée C | Copie profonde par passage de messages (fonctionnellement équivalent) |
| **Pilotes base de données** | Modules C inclus | Implémentation Lua pure (BSON/SHA1 entièrement en Lua) |
# Wiki skynet-cpp

> **skynet-cpp** — Réimplémentation en C++20 moderne du framework Actor [Skynet](https://github.com/cloudwu/skynet)

---

## Bienvenue

skynet-cpp est un framework serveur léger basé sur le modèle Actor, dont la philosophie de conception et la sémantique d'API proviennent de [cloudwu/skynet](https://github.com/cloudwu/skynet). Le framework conserve l'abstraction fondamentale de skynet — **chaque service est un Actor indépendant qui communique par messages asynchrones** — tout en exploitant les fonctionnalités du C++ moderne et son écosystème multiplateforme pour offrir la sécurité des types, la gestion des ressources RAII et l'indépendance vis-à-vis de la plateforme.

Si vous ne connaissez pas du tout skynet-cpp, commencez par lire [GettingStarted](GettingStarted.md). Comme skynet-cpp n'est pas très complexe, il est également recommandé de parcourir le code source.

[Compiler](Build.md) skynet-cpp est très simple, et compiler puis essayer le framework est un excellent point de départ. Si vous souhaitez faire du développement secondaire, vous pouvez commencer par comprendre le [Bootstrap](Bootstrap.md).

Bien que le cœur de skynet-cpp soit écrit en C++, une utilisation simple ne nécessite pas de connaissances en C++. Vous devez comprendre le fonctionnement du modèle Actor et découper votre logique métier en plusieurs services collaboratifs. Lua est le langage de développement nécessaire, et il suffit de connaître Lua pour utiliser l'[API Lua](LuaAPI.md) afin de réaliser la communication et la collaboration entre services. Pour le partage de données entre services, en plus du passage de messages, vous pouvez consulter [ShareData](ShareData.md).

Pour fournir des services aux clients, il faut utiliser l'API [Socket](Socket.md), ou utiliser le modèle de [GateServer](GateServer.md) déjà implémenté pour gérer l'accès d'un grand nombre de clients. Grâce à [SocketChannel](SocketChannel.md), skynet-cpp peut orchestrer de manière asynchrone les événements socket externes. L'accès aux [services externes](ExternalService.md) tels que les bases de données devrait idéalement passer par SocketChannel.

Les fonctionnalités déjà fournies par skynet-cpp sont référencées dans [APIList](APIList.md).

---

## Index de la documentation

### Démarrage

| Document | Description |
|---|---|
| [GettingStarted](GettingStarted.md) | Concepts du framework, modèle Actor, mécanisme de messages, prise en main rapide |
| [Build](Build.md) | Étapes de compilation (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Processus de démarrage : main.cpp → ActorSystem → preload |

### API principales

| Document | Description |
|---|---|
| [LuaAPI](LuaAPI.md) | Référence complète de l'API skynet.lua |
| [Socket](Socket.md) | API Socket TCP/UDP |
| [GateServer](GateServer.md) | Modèle de passerelle TCP + découpage de paquets netpack |
| [SocketChannel](SocketChannel.md) | Multiplexage de connexions TCP |

### Cluster et distribué

| Document | Description |
|---|---|
| [Cluster](Cluster.md) | Cluster RPC inter-nœuds |

### Données et communication inter-services

| Document | Description |
|---|---|
| [ShareData](ShareData.md) | Données partagées en lecture seule |
| [CriticalSection](CriticalSection.md) | File de sérialisation de messages (éviter la pseudo-concurrence) |
| [Multicast](Multicast.md) | Messages publication/abonnement |

### Débogage et outils

| Document | Description |
|---|---|
| [DebugConsole](DebugConsole.md) | Console de débogage + protocole de débogage |
| [CodeCache](CodeCache.md) | Mécanisme de cache de code Lua 5.5 |

### Services externes

| Document | Description |
|---|---|
| [ExternalService](ExternalService.md) | Pilotes Redis / MySQL / MongoDB |

### Référence

| Document | Description |
|---|---|
| [APIList](APIList.md) | Tableau de référence rapide de toutes les API des modules |

---

## Principales différences avec le skynet original

| Dimension | Skynet original (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Langage** | Implémentation en C pur | C++20 (RAII + `std::shared_ptr`) |
| **Plateforme** | Linux uniquement (epoll) | Multiplateforme (Asio : Windows/Linux/macOS) |
| **Sécurité des types** | Messages `void*` | `std::any` + `msg.get<T>()` |
| **Primitives de concurrence** | spinlock maison | File sans verrou `moodycamel::ConcurrentQueue` |
| **IO asynchrone** | Socket server maison | Asio + `steady_timer` |
| **Version Lua** | Lua 5.4 | Lua 5.5.0 (avec codecache) |
| **Système de build** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Mode harbor** | Support master/slave | Non supporté (mode cluster uniquement) |
| **Snax** | Supporté | Non supporté |
| **Sproto** | Supporté | Non supporté |
| **DataCenter** | Supporté | Non supporté (obsolète) |
| **ShareData** | Mémoire partagée C | Copie profonde par passage de messages (fonctionnellement équivalent) |
| **Pilotes de base de données** | Modules C inclus | Implémentation en Lua pur (BSON/SHA1 entièrement en Lua) |

