# Bootstrap

## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

## Vue d'Ensemble

L'entrée C++ effectue uniquement le bootstrap minimal : créer `ActorSystem`, démarrer logger, lire les variables d'environnement, démarrer le LuaActor preload, puis entrer dans la boucle worker/IO/monitor. Launcher n'est plus codé en dur côté C++; le script preload le démarre explicitement avec `skynet.newservice("launcher")`.

## Variables d'Environnement

| Variable | Défaut | Description |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Nombre de workers |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Chemin du script preload |

## Flux de Démarrage

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## Responsabilités du Preload

Le preload est l'unique point d'orchestration du démarrage. Il sert généralement à :

- Appeler `skynet.appendpath` / `skynet.prependpath` pour les chemins Lua.
- Appeler `skynet.appendcpath` pour les modules C.
- Appeler `skynet.appendservicepath` pour les chemins de services.
- Démarrer `launcher`.
- Démarrer l'application, l'exemple, logic, stress ou perf.

## Pathbase et Layout du Paquet

Les valeurs relatives de `SKYNET_PRELOAD` sont résolues depuis le cwd du processus. Les paquets de release doivent être lancés depuis la racine installée, avec `bin/`, `lualib/`, `service/`, `examples/` et `doc/`; le preload par défaut est `examples/preload.lua`. Un preload affiche généralement `skynet.getcwd()`, appelle `skynet.setpathbase(".")`, puis toutes les entrées relatives de `appendpath` / `appendservicepath` / `appendcpath` sont résolues depuis `skynet.getpathbase()`. `setpathbase` ne change pas le cwd OS et n'affecte pas l'IO fichier des bibliothèques tierces.

## Modèle de Threads

| Thread | Nombre | Responsabilité |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | Récupère des `ActorQueue` depuis global queue et dispatch les messages en lots pondérés |
| IO | 1 | Exécute `asio::io_context` pour réseau et timers |
| Monitor | 1 | Détecte les workers bloqués trop longtemps sur le même message |

## Exemple de Preload

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## Entrées Liées

- Exemple : `examples/preload.lua`
- Tests logic : `tests/logic/preload.lua`
- Tests stress : `tests/stress/preload.lua`
- Tests perf : `tests/perf/preload.lua`
