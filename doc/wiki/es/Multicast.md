# Multicast
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Publicación/Suscripción en skynet-cpp

---

```lua
local multicast = require "skynet.multicast"
```

El módulo Multicast proporciona un mecanismo de mensajes basado en canales de publicación/suscripción dentro del mismo proceso.

---

## Método de uso

### Publicador

```lua
local multicast = require "skynet.multicast"

-- Crear nuevo canal
local mc = multicast.new()
print("channel id:", mc.channel)

-- Publicar mensaje (fire-and-forget)
mc:publish("event_name", { data = 123 })

-- Eliminar canal
mc:delete()
```

### Suscriptor

```lua
local multicast = require "skynet.multicast"

-- Usar un ID de canal existente
local mc = multicast.new({ channel = channel_id })

-- Configurar callback de recepción
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- Suscribirse
mc:subscribe()

-- Cancelar suscripción
mc:unsubscribe()
```

---

## API

| Método | Descripción |
|---|---|
| `multicast.new(opts)` | Crear objeto de canal. opts puede contener `{channel=id}` para usar un canal existente |
| `mc:subscribe()` | Suscribir el servicio actual a este canal |
| `mc:unsubscribe()` | Cancelar suscripción |
| `mc:publish(...)` | Publicar mensaje a todos los suscriptores |
| `mc:delete()` | Eliminar este canal |
| `mc.dispatch` | Configurar como función de callback para recibir mensajes publicados |

---

## Arquitectura de implementación

| Componente | Descripción |
|---|---|
| Servicio `multicastd` | Servicio único, gestiona la asignación de IDs de canales, lista de suscriptores, difusión de mensajes |
| Cliente `multicast.lua` | Registra el tipo de protocolo `PTYPE_MULTICAST`, proporciona API orientada a objetos |

Flujo de publicación de mensajes:
1. El publicador llama a `mc:publish(...)`
2. El mensaje se envía al servicio `multicastd`
3. `multicastd` recorre la lista de suscriptores y envía un mensaje de tipo `PTYPE_MULTICAST` a cada suscriptor
4. Se activa el callback dispatch del suscriptor

---

## Diferencias con el skynet original

- La API es básicamente idéntica
- El original soporta multicast entre nodos (distribuido a través de datacenter), skynet-cpp solo soporta dentro del mismo proceso

