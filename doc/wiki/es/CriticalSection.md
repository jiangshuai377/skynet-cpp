# CriticalSection
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Cola de serialización de mensajes de skynet-cpp

---

```lua
local queue = require "skynet.queue"
```

Dentro de un mismo servicio de skynet-cpp, si se llama a una API bloqueante (como `skynet.call`) durante el procesamiento de un mensaje, el servicio se suspenderá. Durante la suspensión, el servicio puede responder a otros mensajes. Esto puede causar problemas de orden temporal que requieren un manejo muy cuidadoso.

En otras palabras, una vez que tu proceso de manejo de mensajes tiene solicitudes externas, los mensajes que llegan primero no necesariamente terminan de procesarse antes que los que llegan después. Después de cada llamada bloqueante, el estado interno del servicio puede no ser el mismo que antes de la llamada.

El módulo `skynet.queue` puede ayudarte a evitar la complejidad causada por esta pseudoconcurrencia.

---

## Método de uso

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs es una cola de ejecución

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 entra en la sección crítica
end

function CMD.foo()
    cs(func2)  -- func2 entra en la sección crítica
end
```

Si utilizas la cola `cs`, entonces `func1` y `func2` no serán interrumpidas mutuamente durante su ejecución.

Si el servicio recibe varios mensajes `foobar` o `foo`, cada uno se procesará completamente antes de procesar el siguiente, incluso si `func1` o `func2` contienen llamadas bloqueantes como `skynet.call`.

---

## Reentrancia

Es legal llamar a cs dentro de la función func1 (no causará deadlock):

```lua
local function func2()
    -- paso 3
end

local function func1()
    -- paso 2
    cs(func2)
    -- paso 4
end

function CMD.foobar()
    -- paso 1
    cs(func1)
    -- paso 5
end
```

Cada vez que se recibe un mensaje foobar, el flujo del programa se ejecutará en el orden paso 1 → 2 → 3 → 4 → 5.

---

## Principio de implementación

queue implementa la planificación FIFO mediante los siguientes mecanismos:

- `current_thread`: Registra la corrutina que actualmente posee el bloqueo
- Contador de referencia `ref`: Soporta llamadas anidadas de la misma corrutina (reentrancia)
- Cola de espera `thread_queue`: Las nuevas solicitudes se encolan al final
- Utiliza `skynet.wait()` / `skynet.wakeup()` para implementar la suspensión y activación entre corrutinas

---

## Diferencias con el skynet original

- La API es completamente idéntica
- La implementación es idéntica (basada en skynet.wait/wakeup)

