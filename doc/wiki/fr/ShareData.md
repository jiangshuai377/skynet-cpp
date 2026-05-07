# ShareData
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Données partagées de skynet-cpp

---

```lua
local sharedata = require "sharedata"
```

Lorsque vous découpez votre logique métier en plusieurs services, le partage de données est le problème le plus fréquemment rencontré. Le module sharedata permet de partager des données structurées en lecture seule entre plusieurs services au sein du même processus. Son usage typique est la distribution de tables de configuration.

---

## Méthode d'utilisation

### Fournisseur de données

```lua
-- Créer des données partagées
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- Mettre à jour les données
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- Supprimer les données
sharedata.delete("game_config")
```

### Consommateur de données

```lua
-- Interroger les données (la première requête lance une coroutine monitor pour surveiller les mises à jour)
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- Après une mise à jour, le prochain accès obtient automatiquement la nouvelle version
-- Obtenir une copie profonde (usage ponctuel, plus efficace)
local copy = sharedata.deepcopy("game_config")
```

---

## API

| Fonction | Description |
|---|---|
| `sharedata.new(name, value)` | Crée des données partagées. value peut être n'importe quelle table Lua |
| `sharedata.query(name)` | Interroge les données partagées. La première requête lance une coroutine monitor qui suit automatiquement les mises à jour |
| `sharedata.update(name, value)` | Met à jour les données partagées. Tous les monitors des détenteurs sont notifiés |
| `sharedata.delete(name)` | Supprime les données partagées |
| `sharedata.flush()` | Vide le cache local, la prochaine requête query récupérera les données depuis le serveur |
| `sharedata.deepcopy(name, ...)` | Obtient une copie profonde des données. Les paramètres supplémentaires servent de chaîne de clés pour indexer une sous-table |

---

## Architecture d'implémentation

```
sharedatad (service unique)                  client sharedata (chaque utilisateur)
├─ data_store[name]                          ├─ local_cache[name]
│   ├─ data (table Lua)                      │   ├─ data
│   └─ version (entier incrémental)          │   └─ version
└─ commandes :                               └─ coroutine monitor :
    new/delete/query/update/monitor             long polling sur sharedatad en attente de changement de version
```

**Flux de données** :
1. Le service A appelle `sharedata.new("cfg", data)` → sharedatad stocke les données
2. Le service B appelle `sharedata.query("cfg")` → récupère les données depuis sharedatad + lance le monitor
3. Le service A appelle `sharedata.update("cfg", new_data)` → sharedatad met à jour + notifie tous les monitors
4. Le monitor du service B reçoit la notification → met à jour automatiquement le cache local

---

## Différences avec le skynet original

- Le sharedata original utilise la mémoire partagée C, où plusieurs VM Lua peuvent lire directement le même bloc mémoire. skynet-cpp transmet les données par copie profonde via le passage de messages, fonctionnellement équivalent mais sans mémoire partagée
- L'original a le module `sharetable` (basé sur `lua_clonefunction`), non supporté par skynet-cpp
- L'objet obtenu par query dans l'original peut être lu comme une table ordinaire (via la métaméthode `__index`), skynet-cpp retourne directement une table ordinaire
- L'original a les modules STM / ShareMap, non supportés par skynet-cpp

