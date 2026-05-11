# CodeCache
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Mécanisme de cache de code Lua 5.5

---

## Présentation

skynet-cpp utilise une version modifiée de Lua 5.5.0 par skynet, qui inclut le mécanisme de **codecache**. Ce mécanisme permet à plusieurs VM Lua (c'est-à-dire plusieurs services) de partager les prototypes de fonctions Lua compilées (Proto), offrant ainsi :

1. **Économie de mémoire** : Le même script n'est compilé qu'une seule fois en bytecode
2. **Accélération du démarrage** : Les VM suivantes chargeant le même script le réutilisent directement, sans nouvelle analyse

---

## Fonctionnement

Lorsqu'un service Lua charge un script via `loadfile` :

1. **Premier chargement** : Compilation normale, le prototype de fonction compilé est stocké dans le cache global
2. **Chargements suivants** : Le prototype de fonction est cloné directement depuis le cache, sans étape de compilation

Extensions clés de l'API C :
- `lua_clonefunction(L, proto)` — Crée une nouvelle fermeture (closure) à partir d'un prototype partagé
- `lua_sharefunction(L, index)` — Ajoute le prototype de fonction au pool de partage

---

## Utilisation dans skynet-cpp

Dans `loader.lua`, le codecache est désactivé par défaut (`cache.mode("OFF")`), pour les raisons suivantes :

- Chaque `LuaActor` de skynet-cpp possède un `lua_State` indépendant, et les `_ENV` de chaque VM sont complètement isolés
- Si le codecache est activé, plusieurs VM partagent le même Proto compilé, mais les environnements globaux (`_ENV`) de chaque VM diffèrent. Lorsque le Proto référence des fonctions globales comme `require`, le `_ENV` peut pointer vers la mauvaise VM
- Avec le codecache désactivé, chaque VM compile les scripts indépendamment, et `_ENV` pointe correctement

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- Désactiver le cache partagé
```

---

## Contrôle manuel

Si vous confirmez que certains scripts de fonctions pures ne dépendent pas de `_ENV`, vous pouvez activer sélectivement le cache :

```lua
local cache = require "cache"

-- Interroger le mode actuel
local mode = cache.mode()

-- Définir le mode : ON / OFF
cache.mode("ON")   -- Activer le cache partagé
cache.mode("OFF")  -- Désactiver le cache partagé
```

---

## Différences avec le skynet original

- Le skynet original active le codecache par défaut, skynet-cpp le désactive par défaut
- L'original obtient l'interface de contrôle via `require "skynet.codecache"`, skynet-cpp via `require "cache"`
- L'original fournit `codecache.clear()` pour vider le cache, non encore supporté par skynet-cpp

