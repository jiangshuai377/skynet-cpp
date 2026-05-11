# GateServer
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Modèle de service de passerelle skynet-cpp

---

Le service de passerelle (GateServer) est la couche d'accès de l'application. Sa fonction principale est de gérer les connexions client, de découper les paquets de données complets et de les transférer aux services logiques.

skynet-cpp fournit un modèle générique `lualib/gateserver.lua`.

---

## Méthode d'utilisation

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- Nouveau client connecté
end

function handler.disconnect(conn_id)
    -- Client déconnecté
end

function handler.message(conn_id, data)
    -- Paquet de données métier complet reçu (en-tête de longueur retiré)
end

function handler.open(source, conf)
    -- Le Gate ouvre le port d'écoute
end

gateserver.start(handler)
```

Note : `gateserver.start` appelle `skynet.start` en interne.

---

## Callbacks du Handler

| Callback | Signature | Description |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | Appelé après l'acceptation d'un nouveau client |
| `disconnect` | `(conn_id)` | Appelé lors de la déconnexion |
| `message` | `(conn_id, data)` | Paquet métier complet (découpé par netpack) arrivé |
| `error` | `(conn_id, msg)` | Anomalie de connexion |
| `warning` | `(conn_id, bytes)` | Alerte lorsque le tampon d'envoi dépasse 1 Mo |
| `open` | `(source, conf)` | Appelé lors de l'ouverture du port d'écoute |

---

## Protocole de découpage

Chaque paquet = **en-tête de longueur 2 octets big-endian** + **contenu des données**

Un seul paquet de données ne doit pas dépasser 65535 octets. Si la logique métier nécessite le transfert de blocs de données plus grands, cela doit être résolu au niveau du protocole supérieur.

### API netpack

```lua
local netpack = require "netpack"
```

| Fonction | Description |
|---|---|
| `netpack.pack(data)` | Empaquète les données (ajoute un en-tête de longueur 2 octets), retourne une chaîne encadrée |
| `netpack.unpack(buffer, offset)` | Extrait une trame complète du buffer, retourne (next_offset, payload) |
| `netpack.filter(buffer, new_data)` | Fusionne les nouvelles données et extrait toutes les trames complètes |
| `netpack.tostring(msg, sz)` | Convertit lightuserdata en chaîne Lua |

---

## Commandes de contrôle

D'autres services peuvent envoyer les commandes suivantes au gate via le protocole lua :

```lua
-- Ouvrir l'écoute
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- Envoyer des données avec en-tête de longueur
skynet.call(gate, "lua", "SEND", conn_id, data)

-- Envoyer des données brutes (sans en-tête de longueur)
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- Fermer une connexion
skynet.call(gate, "lua", "CLOSE", conn_id)

-- Expulser une connexion
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## Différences avec le skynet original

- Le gateserver original se trouve dans `lualib/snax/gateserver.lua`, celui de skynet-cpp dans `lualib/gateserver.lua`
- L'original a `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` pour contrôler la réception des messages, dans skynet-cpp les connexions reçoivent les messages par défaut
- Le callback message de l'original transmet un pointeur C et une longueur `(fd, msg, sz)`, skynet-cpp transmet une chaîne Lua `(conn_id, data)`
- L'original ne peut pas être utilisé avec la bibliothèque socket dans le même service, il en va de même pour skynet-cpp

