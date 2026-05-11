# Socket
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> API Socket de skynet-cpp

---

```lua
local socket = require "socket"
```

skynet-cpp fournit un ensemble d'API Lua en mode bloquant pour la lecture/écriture TCP/UDP. Le mode bloquant exploite en réalité le mécanisme de coroutine de Lua. Lorsque vous appelez une API socket, le service peut être suspendu (la tranche de temps est cédée à d'autres traitements métier), et lorsque le résultat arrive via un message socket, la coroutine reprend son exécution.

---

## API TCP

### Côté serveur

```lua
-- Écouter un port
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- Nouvelle connexion acceptée
    elseif event == "close" then
        -- Connexion fermée
    elseif event == "warning" then
        -- Alerte tampon d'envoi
    end
end)

-- Définir le callback de données
socket.ondata(listener_id, function(conn_id, data)
    -- Données reçues
end)
```

- `socket.listen(host, port, handler)` — Écoute un port, handler reçoit les événements accept/close/warning, retourne listener_id
- `socket.ondata(listener_id, handler)` — Définit le callback de données `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — Envoie des données sur une connexion du listener
- `socket.close_listener(listener_id)` — Ferme l'écoute
- `socket.pause(listener_id, conn_id)` — Met en pause la lecture de la connexion (contrôle de flux)
- `socket.resume(listener_id, conn_id)` — Reprend la lecture de la connexion

### Côté client

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — Se connecte à un hôte distant, bloque jusqu'à ce que la connexion soit établie ou échoue
- `socket.send(conn_id, data)` — Envoie des données
- `socket.read(conn_id, sz)` — Lit sz octets, bloque jusqu'à ce que les données soient prêtes ou que la connexion soit fermée
- `socket.readline(conn_id, sep)` — Lit jusqu'au séparateur (par défaut `"\n"`), sans le séparateur
- `socket.readall(conn_id)` — Lit toutes les données disponibles
- `socket.close(conn_id)` — Ferme la connexion

---

## API UDP

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- Paquet UDP reçu
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — Crée un socket UDP, le callback reçoit les paquets de données
- `socket.udp_send(id, data, host, port)` — Envoie un paquet UDP

---

## socketdriver (module C)

`socket.lua` est un wrapper coroutine du module C sous-jacent `socketdriver`. Les fonctions enregistrées par `socketdriver` sont :

| Fonction | Description |
|---|---|
| `socketdriver.listen(host, port, backlog)` | Crée une écoute TCP |
| `socketdriver.connect(host, port)` | Crée une connexion TCP (asynchrone) |
| `socketdriver.send(id, data)` | Envoie des données via un connecteur |
| `socketdriver.write(listener_id, conn_id, data)` | Envoie via une connexion du listener |
| `socketdriver.close(id, [conn_id])` | Ferme un socket ou une connexion |
| `socketdriver.pause(listener_id, conn_id)` | Met en pause la lecture de la connexion |
| `socketdriver.resume(listener_id, conn_id)` | Reprend la lecture de la connexion |
| `socketdriver.udp(host, port)` | Crée un socket UDP |
| `socketdriver.udp_send(id, data, host, port)` | Envoie un paquet UDP |

---

## Différences avec le skynet original

- L'original utilise `socket.start(id)` pour prendre le contrôle d'un socket (car plusieurs services partagent les id de socket), dans skynet-cpp le listener/connector est naturellement lié au service créateur
- L'original a `socket.abandon` (transfert de contrôle), non encore implémenté dans skynet-cpp
- L'original a `socket.lwrite` (file d'écriture basse priorité), non encore implémenté dans skynet-cpp
- L'original a `socket.block` (attente de lisibilité), non encore implémenté dans skynet-cpp

