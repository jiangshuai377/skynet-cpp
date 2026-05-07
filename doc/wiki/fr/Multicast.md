# Multicast
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Publication/abonnement de skynet-cpp

---

```lua
local multicast = require "skynet.multicast"
```

Le module Multicast fournit un mécanisme de messagerie de type publication/abonnement par canal au sein d'un même processus.

---

## Méthode d'utilisation

### Éditeur (Publisher)

```lua
local multicast = require "skynet.multicast"

-- Créer un nouveau canal
local mc = multicast.new()
print("channel id:", mc.channel)

-- Publier un message (fire-and-forget)
mc:publish("event_name", { data = 123 })

-- Supprimer le canal
mc:delete()
```

### Abonné (Subscriber)

```lua
local multicast = require "skynet.multicast"

-- Utiliser un ID de canal existant
local mc = multicast.new({ channel = channel_id })

-- Définir le callback de réception
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- S'abonner
mc:subscribe()

-- Se désabonner
mc:unsubscribe()
```

---

## API

| Méthode | Description |
|---|---|
| `multicast.new(opts)` | Crée un objet canal. opts peut contenir `{channel=id}` pour utiliser un canal existant |
| `mc:subscribe()` | Abonne le service courant à ce canal |
| `mc:unsubscribe()` | Se désabonne |
| `mc:publish(...)` | Publie un message à tous les abonnés |
| `mc:delete()` | Supprime ce canal |
| `mc.dispatch` | À définir comme fonction callback pour recevoir les messages publiés |

---

## Architecture d'implémentation

| Composant | Description |
|---|---|
| Service `multicastd` | Service unique, gère l'allocation des ID de canaux, la liste des abonnés, la diffusion des messages |
| Client `multicast.lua` | Enregistre le type de protocole `PTYPE_MULTICAST`, fournit une API orientée objet |

Processus de publication des messages :
1. L'éditeur appelle `mc:publish(...)`
2. Le message est envoyé au service `multicastd`
3. `multicastd` parcourt la liste des abonnés et envoie un message `PTYPE_MULTICAST` à chaque abonné
4. Le callback dispatch de l'abonné est déclenché

---

## Différences avec le skynet original

- API essentiellement identiques
- L'original supporte la multidiffusion inter-nœuds (distribution via datacenter), skynet-cpp ne supporte que la diffusion au sein du même processus

