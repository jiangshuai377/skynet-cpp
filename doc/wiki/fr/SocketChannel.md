# SocketChannel
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Multiplexage de connexions Socket de skynet-cpp

---

```lua
local socketchannel = require "skynet.socketchannel"
```

Le mode requête-réponse est l'un des patterns les plus couramment utilisés pour interagir avec des services externes. socketchannel fournit une encapsulation de haut niveau, supportant deux conceptions de protocole :

1. **Mode séquentiel (Order Mode)** : Chaque requête correspond à une réponse, l'ordre est garanti par TCP (ex : Redis)
2. **Mode session (Session Mode)** : Chaque requête porte un session unique, la réponse renvoie le session pour le matching (ex : MongoDB)

---

## Création d'un Channel

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- Paramètres optionnels :
    response = dispatch_func,   -- Si fourni, active le mode Session
    auth = auth_func,           -- Callback d'authentification après connexion
    nodelay = true,             -- TCP_NODELAY
}
```

Le socket channel ne crée pas immédiatement la connexion lors de sa création. La connexion est différée jusqu'au premier `request`. Après une déconnexion, le prochain `request` se reconnectera automatiquement.

---

## Mode séquentiel (Order Mode)

Adapté aux protocoles comme Redis où chaque requête a exactement une réponse dans l'ordre :

```lua
local resp = channel:request(req_string, function(sock)
    -- sock est l'objet de lecture passé par le channel
    local line = sock:readline()
    return true, line  -- Première valeur de retour : succès ; deuxième : contenu de la réponse
end)
```

La première valeur de retour de la fonction response est un boolean :
- `true` : Analyse du protocole normale
- `false` : Erreur de protocole, la connexion sera fermée, request lève une erreur

---

## Mode session (Session Mode)

Adapté aux protocoles comme MongoDB où les réponses peuvent arriver dans le désordre. Nécessite de fournir une fonction `response` globale à la création :

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- Analyser le paquet de réponse
        local session = ...  -- Extraire le session de la réponse
        local ok = true
        local data = ...     -- Analyser les données de réponse
        return session, ok, data
    end,
}

-- Envoyer une requête, passer le session au lieu de la fonction response
local resp = channel:request(req_string, session_id)
```

---

## Authentification

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- Appelé automatiquement après l'établissement de la connexion
        -- Permet d'effectuer AUTH / SELECT etc.
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

La fonction auth est exécutée immédiatement après chaque établissement de connexion. En cas d'échec d'authentification, il suffit de lever une erreur dans auth.

---

## Autres API

| Méthode | Description |
|---|---|
| `channel:connect(once)` | Connexion explicite. once=true signifie une seule tentative, échec = erreur |
| `channel:close()` | Ferme le channel, réveille tous les request en attente |
| `channel:changehost(host, port)` | Change l'adresse distante et reconnecte |
| `channel:read(sz)` | Lit sz octets depuis le channel |
| `channel:readline(sep)` | Lit depuis le channel par séparateur |
| `channel:response(func)` | Sans envoyer de requête, attend uniquement la réception d'une réponse (utilisé pour pub/sub) |

---

## Différences avec le skynet original

- API essentiellement identiques
- L'original a le paramètre `padding` et l'écriture basse priorité (`socket.lwrite`), non encore implémentés dans skynet-cpp
- L'original a `backup` comme adresse de secours (conçu pour les clusters mongo), non encore implémenté dans skynet-cpp
- L'original a le callback `overload` de surcharge, non encore implémenté dans skynet-cpp

