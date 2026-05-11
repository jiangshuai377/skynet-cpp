# LuaAPI
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Referencia de la API Lua de servicios skynet

---

```lua
local skynet = require "skynet"
```

Cada servicio de skynet-cpp necesita importar el módulo `skynet`. Este módulo no puede usarse fuera del framework skynet-cpp.

---

## Dirección del servicio

Cada servicio tiene una dirección numérica de 32 bits (handle).

- `skynet.self()` — Devuelve la dirección del servicio actual
- `skynet.address(addr)` — Convierte la dirección a una cadena legible (formato `:xxxxxxxx`)
- `skynet.register(name)` — Registra un alias para el servicio actual (con prefijo `.` para nombres locales)
- `skynet.name(name, handle)` — Registra un alias para el servicio con el handle especificado
- `skynet.localname(name)` — Consulta la dirección correspondiente a un nombre local (no bloqueante)

Todos los parámetros de API que aceptan direcciones de servicio también pueden recibir alias de tipo cadena.

---

## Distribución y respuesta de mensajes

### skynet.dispatch(type, func)

Registra la función de manejo para un tipo específico de mensaje. El uso más común:

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

Registra una nueva categoría de mensaje. class debe proporcionar los campos `name`, `id`, `pack`, `unpack`.

### skynet.ret(msg, sz)

Responde el mensaje al emisor de la solicitud actual. Solo puede llamarse una vez dentro de la misma corrutina de manejo de mensaje.

### skynet.retpack(...)

Atajo para `skynet.ret(skynet.pack(...))`.

### skynet.response([packfunc])

Genera un closure de respuesta diferida, que puede ser invocado en el futuro desde otra corrutina.

```lua
local resp = skynet.response()
-- Llamar más tarde en otro lugar:
resp(true, result1, result2)   -- Respuesta normal
resp(false)                     -- Lanzar excepción al solicitante
```

---

## Envío de mensajes y llamadas remotas

### skynet.send(addr, typename, ...)

Envía un mensaje de tipo typename a addr. API no bloqueante, el mensaje se empaqueta mediante la función pack.

### skynet.call(addr, typename, ...)

Envía una solicitud a addr y bloquea esperando la respuesta. La respuesta se desempaqueta mediante unpack antes de retornar. **Nota**: `skynet.call` solo bloquea la corrutina actual, el servicio puede seguir respondiendo a otros mensajes.

### skynet.rawsend(addr, typename, msg, sz)

Envío en crudo, sin pasar por el empaquetado pack.

### skynet.rawcall(addr, typename, msg, sz)

Llamada RPC en crudo, sin pasar por pack/unpack.

### skynet.redirect(addr, source, typename, session, ...)

Envía un mensaje a addr haciéndose pasar por la dirección source.

---

## Reloj y hilos

La precisión del reloj interno es de 1/100 de segundo (centésimas de segundo).

- `skynet.now()` — Devuelve el tiempo transcurrido desde el inicio del proceso (centésimas de segundo)
- `skynet.starttime()` — Devuelve el tiempo UTC de inicio del proceso (segundos)
- `skynet.time()` — Devuelve el tiempo UTC actual (segundos, precisión de 10ms)

### skynet.sleep(ti)

Suspende la corrutina actual por ti centésimas de segundo. Devuelve `"BREAK"` si es despertada por `wakeup`.

### skynet.yield()

Equivalente a `skynet.sleep(0)`. Cede el control de CPU.

### skynet.timeout(ti, func)

Ejecuta func en una nueva corrutina después de ti centésimas de segundo. API no bloqueante.

### skynet.fork(func, ...)

Inicia una nueva corrutina para ejecutar func. Más eficiente que `timeout(0, ...)` (no pasa por el temporizador).

### skynet.wait(token)

Suspende la corrutina actual, esperando ser despertada por `wakeup`. El token por defecto es `coroutine.running()`.

### skynet.wakeup(token)

Despierta una corrutina suspendida por `sleep` o `wait`.

---

## Inicio y salida de servicios

### skynet.start(func)

Registra la función de arranque del servicio. **Debe llamarse obligatoriamente**, es el punto de entrada del servicio.

### skynet.exit()

Sale del servicio actual. El código posterior no se ejecutará y las corrutinas suspendidas serán interrumpidas.

### skynet.newservice(name, ...)

Inicia un nuevo servicio Lua. API bloqueante, espera a que la función `start` del servicio iniciado retorne.

### skynet.uniqueservice(name, ...)

Inicia un servicio único. Si ya está iniciado, devuelve la dirección existente.

### skynet.queryservice(name)

Consulta la dirección de un servicio único. Si aún no se ha iniciado, espera.

## Path Configuration

These APIs are normally called from the preload script. Each argument is a plain directory path; the runtime normalizes `/`, `\`, duplicate separators, and trailing separators, then expands Lua/C module or service search rules internally. Newly created LuaActors inherit the current global path snapshot.

- `skynet.appendpath(path)` — Append a Lua module directory, expanded to `path/?.lua` and `path/?/init.lua`.
- `skynet.prependpath(path)` — Prepend a Lua module directory.
- `skynet.appendcpath(path)` — Append a C module directory, expanded to the platform `.dll` or `.so` search pattern.
- `skynet.appendservicepath(path)` — Append a service script directory, expanded to `path/?.lua`.
- `skynet.getpath()` — Return the current `{ path, cpath, service_path }` snapshot.
- `skynet.getcwd()` — Return the process current working directory for preload logging and path debugging.
- `skynet.setpathbase(path)` — Set the relative base used by path APIs without changing the OS cwd.
- `skynet.getpathbase()` — Return the current pathbase.
- `skynet.readfile(path)` / `skynet.writefile(path, data, append)` — Controlled file read/write helpers that resolve paths from pathbase.
- `skynet.systemstat()` — Return process-level runtime stats such as actor count, global queue backlog, and worker count.

---

## Serialización

- `skynet.pack(...)` — Serializa valores Lua a `(lightuserdata, size)`
- `skynet.unpack(msg, sz)` — Deserializa a valores Lua
- `skynet.packstring(...)` — Serializa a un string Lua
- `skynet.tostring(msg, sz)` — Convierte lightuserdata a string Lua
- `skynet.trash(msg, sz)` — Libera el buffer de lightuserdata

Tipos soportados: string, boolean, number, lightuserdata, table (sin metatabla).

---

## Logging

### skynet.error(...)

Concatena los parámetros y los envía al servicio logger. Formato de salida: `[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## Consulta de estado

- `skynet.info_func(func)` — Registra una función de consulta de estado interno, invocable por el protocolo de depuración
- `skynet.stat(what)` — Consulta el estado interno del servicio: `"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## Otros

- `skynet.getenv(key)` — Lee variables de entorno
- `skynet.setenv(key, value)` — Establece variables de entorno (no se pueden sobrescribir)
- `skynet.genid()` — Genera un session único
- `skynet.harbor(addr)` — Siempre devuelve 0 (skynet-cpp no soporta harbor)

---

## Diferencias con el skynet original

- `skynet.harbor()` siempre devuelve 0
- No soporta `skynet.forward_type` ni `skynet.filter` (reenvío avanzado de mensajes)
- `skynet.memlimit` debe llamarse antes de `start`
- Las variables de entorno se pasan mediante `ActorSystem` en lugar de archivos de configuración


