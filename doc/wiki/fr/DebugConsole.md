# DebugConsole
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Console de débogage et protocole de débogage de skynet-cpp

---

## Protocole de débogage

Chaque service Lua enregistre automatiquement le protocole `PTYPE_DEBUG`, avec les commandes de débogage intégrées suivantes :

| Commande | Description |
|---|---|
| `MEM` | Retourne la consommation mémoire de la VM Lua courante (Ko) |
| `GC` | Déclenche la collecte des déchets, rapporte les changements de mémoire |
| `STAT` | Retourne le nombre de tâches, la longueur de la file de messages, les statistiques CPU |
| `TASK` | Retourne les informations de pile des coroutines de tâches |
| `INFO` | Appelle le callback `info_func` enregistré par le service pour obtenir des informations personnalisées |
| `EXIT` | Arrêt gracieux du service |
| `PING` | Détection de disponibilité (réponse immédiate) |
| `RUN` | Injecte et exécute un fragment de code Lua |

### Enregistrement de commandes de débogage personnalisées

```lua
local skynet = require "skynet"
require "skynet.debug"

-- Enregistrer un callback INFO personnalisé
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- Enregistrer une commande de débogage personnalisée
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## Console de débogage

`debug_console.lua` fournit une interface TCP telnet permettant d'exécuter des commandes de débogage de manière interactive après connexion.

### Démarrage

```lua
-- Démarrer la console de débogage dans preload.lua
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### Connexion

```bash
telnet 127.0.0.1 8000
```

### Commandes de la console

| Commande | Paramètres | Description |
|---|---|---|
| `help` | — | Liste toutes les commandes |
| `list` | — | Liste tous les services en cours d'exécution |
| `mem` | [timeout] | Interroge l'état mémoire de tous les services |
| `gc` | [timeout] | Déclenche le GC sur tous les services |
| `stat` | [timeout] | Interroge les statistiques de tous les services |
| `ping` | address | Vérifie si un service est actif |
| `info` | address, ... | Obtient les informations personnalisées d'un service |
| `exit` | address | Arrêt gracieux du service spécifié |
| `kill` | address | Terminaison forcée du service spécifié |
| `start` | name, ... | Démarre un nouveau service Lua |
| `inject` | address, code | Injecte du code Lua dans un service pour exécution |

---

## Profilage de performance

```lua
local profile = require "skynet.profile"
```

Chronométrage CPU au niveau des coroutines fourni via le module C `lua_profile.cpp` :

| Fonction | Description |
|---|---|
| `profile.start([co])` | Commence le chronométrage de la coroutine (par défaut le thread courant) |
| `profile.stop([co])` | Arrête le chronométrage, retourne le temps CPU (en secondes) |
| `profile.resume(co, ...)` | coroutine.resume avec chronométrage |
| `profile.wrap(f)` | Crée un wrapper de coroutine avec chronométrage |

```lua
profile.start()
-- Exécuter des opérations gourmandes en calcul
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## Différences avec le skynet original

- Ensemble de commandes du protocole de débogage essentiellement identique
- L'original a la fonctionnalité `signal` (interrompre du code Lua en boucle infinie), non encore implémentée dans skynet-cpp
- L'original a `skynet.trace()` pour le journal de suivi des messages, non encore implémenté dans skynet-cpp

