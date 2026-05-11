# SocketChannel
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Multiplexación de conexiones Socket en skynet-cpp

---

```lua
local socketchannel = require "skynet.socketchannel"
```

El patrón solicitud-respuesta es uno de los más utilizados al interactuar con servicios externos. socketchannel proporciona una encapsulación de alto nivel que soporta dos diseños de protocolo:

1. **Modo ordenado (Order Mode)**: Cada solicitud corresponde a una respuesta, TCP garantiza el orden (por ejemplo, Redis)
2. **Modo sesión (Session Mode)**: Cada solicitud lleva un session único, la respuesta devuelve el session para el emparejamiento (por ejemplo, MongoDB)

---

## Crear un Channel

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- Los siguientes son parámetros opcionales:
    response = dispatch_func,   -- Si se proporciona, entra en modo Session
    auth = auth_func,           -- Callback de autenticación después de establecer la conexión
    nodelay = true,             -- TCP_NODELAY
}
```

El socket channel no establece la conexión inmediatamente al crearse. La conexión se pospone hasta el primer `request`. Si la conexión se desconecta, el siguiente `request` se reconectará automáticamente.

---

## Modo ordenado (Order Mode)

Adecuado para protocolos como Redis donde cada solicitud tiene exactamente una respuesta en orden:

```lua
local resp = channel:request(req_string, function(sock)
    -- sock es el objeto de lectura pasado por el channel
    local line = sock:readline()
    return true, line  -- Primer valor de retorno: éxito o no; segundo: contenido de la respuesta
end)
```

El primer valor de retorno de la función response es un boolean:
- `true`: El análisis del protocolo es correcto
- `false`: Error en el protocolo, la conexión se desconectará, request lanza un error

---

## Modo sesión (Session Mode)

Adecuado para protocolos como MongoDB que pueden responder en desorden. Requiere proporcionar una función `response` global al crear:

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- Analizar paquete de respuesta
        local session = ...  -- Extraer session de la respuesta
        local ok = true
        local data = ...     -- Analizar datos de respuesta
        return session, ok, data
    end,
}

-- Enviar solicitud, pasar session en lugar de función response
local resp = channel:request(req_string, session_id)
```

---

## Autenticación

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- Se llama automáticamente después de establecer la conexión
        -- Se puede hacer AUTH / SELECT y otras operaciones
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

La función auth se ejecuta inmediatamente después de que se establece cada conexión. Si la autenticación falla, simplemente lanza un error dentro de auth.

---

## Otras APIs

| Método | Descripción |
|---|---|
| `channel:connect(once)` | Conectar explícitamente. once=true significa intentar solo una vez, si falla lanza error |
| `channel:close()` | Cerrar el channel, despertar todos los request en espera |
| `channel:changehost(host, port)` | Cambiar la dirección remota y reconectar |
| `channel:read(sz)` | Leer sz bytes del channel |
| `channel:readline(sep)` | Leer del channel según separador |
| `channel:response(func)` | No enviar solicitud, solo esperar a recibir una respuesta (para pub/sub) |

---

## Diferencias con el skynet original

- La API es básicamente idéntica
- El original tiene el parámetro `padding` y escritura de baja prioridad (`socket.lwrite`), skynet-cpp aún no lo ha implementado
- El original tiene direcciones de respaldo `backup` (diseñado para clústeres de Mongo), skynet-cpp aún no lo ha implementado
- El original tiene el callback `overload` de sobrecarga, skynet-cpp aún no lo ha implementado

