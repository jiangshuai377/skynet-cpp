# GateServer
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`, con runners separados para coverage y perf Linux Docker. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Plantilla de servicio gateway de skynet-cpp

---

El servicio gateway (GateServer) es la capa de acceso de la aplicación, cuya función básica es gestionar las conexiones de clientes, dividir los paquetes de datos completos y reenviarlos a los servicios de lógica.

skynet-cpp proporciona una plantilla genérica en `lualib/gateserver.lua`.

---

## Método de uso

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- Nuevo cliente conectado
end

function handler.disconnect(conn_id)
    -- Cliente desconectado
end

function handler.message(conn_id, data)
    -- Paquete de datos de negocio completo recibido (sin cabecera de longitud)
end

function handler.open(source, conf)
    -- Gate abre el puerto de escucha
end

gateserver.start(handler)
```

Nota: `gateserver.start` internamente llama a `skynet.start`.

---

## Callbacks del Handler

| Callback | Firma | Descripción |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | Llamado después de aceptar un nuevo cliente |
| `disconnect` | `(conn_id)` | Llamado cuando la conexión se desconecta |
| `message` | `(conn_id, data)` | Paquete completo de negocio recibido (dividido por netpack) |
| `error` | `(conn_id, msg)` | Excepción en la conexión |
| `warning` | `(conn_id, bytes)` | Alerta cuando el buffer de envío supera 1M |
| `open` | `(source, conf)` | Llamado cuando se abre el puerto de escucha |

---

## Protocolo de empaquetado

Cada paquete = **2 bytes de cabecera de longitud big-endian** + **contenido de datos**

Un paquete de datos individual no puede superar los 65535 bytes. Si la lógica de negocio necesita transferir bloques de datos más grandes, resuélvalo en el protocolo de nivel superior.

### API de netpack

```lua
local netpack = require "netpack"
```

| Función | Descripción |
|---|---|
| `netpack.pack(data)` | Empaqueta los datos (añade cabecera de 2 bytes), devuelve framed string |
| `netpack.unpack(buffer, offset)` | Extrae un frame completo del buffer, devuelve (next_offset, payload) |
| `netpack.filter(buffer, new_data)` | Fusiona nuevos datos y extrae todos los frames completos |
| `netpack.tostring(msg, sz)` | Convierte lightuserdata a string Lua |

---

## Comandos de control

Otros servicios pueden enviar los siguientes comandos al gate a través del protocolo lua:

```lua
-- Abrir escucha
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- Enviar datos con cabecera de longitud
skynet.call(gate, "lua", "SEND", conn_id, data)

-- Enviar datos en crudo (sin cabecera de longitud)
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- Cerrar conexión
skynet.call(gate, "lua", "CLOSE", conn_id)

-- Expulsar conexión
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## Diferencias con el skynet original

- El gateserver original se encuentra en `lualib/snax/gateserver.lua`, en skynet-cpp se encuentra en `lualib/gateserver.lua`
- El original tiene `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` para controlar la recepción de mensajes, en skynet-cpp las conexiones reciben mensajes por defecto
- El callback message del original pasa un puntero C y longitud `(fd, msg, sz)`, skynet-cpp pasa un string Lua `(conn_id, data)`
- El original no puede mezclarse con la biblioteca socket en el mismo servicio, lo mismo aplica en skynet-cpp

