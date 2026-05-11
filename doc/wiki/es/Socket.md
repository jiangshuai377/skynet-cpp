# Socket
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> API de Socket de skynet-cpp

---

```lua
local socket = require "socket"
```

skynet-cpp proporciona un conjunto de APIs Lua en modo bloqueante para lectura/escritura TCP/UDP. El llamado modo bloqueante en realidad utiliza el mecanismo de coroutines de Lua. Cuando llamas a la API de socket, el servicio puede ser suspendido (cediendo el timeslice a otros procesos de negocio), y cuando el resultado regresa a través de un mensaje de socket, la coroutine reanuda su ejecución.

---

## API TCP

### Servidor

```lua
-- Escuchar puerto
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- Nueva conexión aceptada
    elseif event == "close" then
        -- Conexión cerrada
    elseif event == "warning" then
        -- Alerta de buffer de envío
    end
end)

-- Configurar callback de datos
socket.ondata(listener_id, function(conn_id, data)
    -- Datos recibidos
end)
```

- `socket.listen(host, port, handler)` — Escucha el puerto, handler recibe eventos accept/close/warning, devuelve listener_id
- `socket.ondata(listener_id, handler)` — Configura el callback de datos `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — Envía datos en una conexión del listener
- `socket.close_listener(listener_id)` — Cierra el listener
- `socket.pause(listener_id, conn_id)` — Pausa la lectura de la conexión (control de flujo)
- `socket.resume(listener_id, conn_id)` — Reanuda la lectura de la conexión

### Cliente

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — Conecta a un host remoto, bloquea hasta que la conexión se establece o falla
- `socket.send(conn_id, data)` — Envía datos
- `socket.read(conn_id, sz)` — Lee sz bytes, bloquea hasta que los datos estén disponibles o la conexión se cierre
- `socket.readline(conn_id, sep)` — Lee hasta el separador (por defecto `"\n"`), sin incluir el separador
- `socket.readall(conn_id)` — Lee todos los datos disponibles
- `socket.close(conn_id)` — Cierra la conexión

---

## API UDP

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- Paquete UDP recibido
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — Crea un socket UDP, el callback recibe paquetes de datos
- `socket.udp_send(id, data, host, port)` — Envía un paquete UDP

---

## socketdriver (módulo C)

`socket.lua` es un envoltorio de coroutines sobre el módulo C de bajo nivel `socketdriver`. Las funciones registradas por `socketdriver` incluyen:

| Función | Descripción |
|---|---|
| `socketdriver.listen(host, port, backlog)` | Crear listener TCP |
| `socketdriver.connect(host, port)` | Crear conexión TCP (asíncrona) |
| `socketdriver.send(id, data)` | Enviar datos a través de connector |
| `socketdriver.write(listener_id, conn_id, data)` | Enviar a través de una conexión del listener |
| `socketdriver.close(id, [conn_id])` | Cerrar socket o conexión |
| `socketdriver.pause(listener_id, conn_id)` | Pausar lectura de conexión |
| `socketdriver.resume(listener_id, conn_id)` | Reanudar lectura de conexión |
| `socketdriver.udp(host, port)` | Crear socket UDP |
| `socketdriver.udp_send(id, data, host, port)` | Enviar UDP |

---

## Diferencias con el skynet original

- El original usa `socket.start(id)` para tomar el control del socket (porque múltiples servicios comparten el socket id), en skynet-cpp el listener/connector está nativamente vinculado al servicio creador
- El original tiene `socket.abandon` (transferir el control), skynet-cpp aún no lo ha implementado
- El original tiene `socket.lwrite` (cola de escritura de baja prioridad), skynet-cpp aún no lo ha implementado
- El original tiene `socket.block` (esperar lectura disponible), skynet-cpp aún no lo ha implementado

