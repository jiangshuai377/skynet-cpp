# DebugConsole
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Consola de depuración y protocolo de depuración de skynet-cpp

---

## Protocolo de depuración

Cada servicio Lua registra automáticamente el protocolo `PTYPE_DEBUG`, con los siguientes comandos de depuración integrados:

| Comando | Descripción |
|---|---|
| `MEM` | Devuelve el uso de memoria de la VM Lua actual (KB) |
| `GC` | Activa la recolección de basura, reporta los cambios de memoria |
| `STAT` | Devuelve el número de tareas, longitud de la cola de mensajes, estadísticas de CPU |
| `TASK` | Devuelve la información de la pila de las corrutinas de tareas |
| `INFO` | Llama al callback `info_func` registrado por el servicio para obtener información personalizada |
| `EXIT` | Salida elegante del servicio |
| `PING` | Detección de actividad (respuesta inmediata) |
| `RUN` | Inyecta y ejecuta un fragmento de código Lua |

### Registrar comandos de depuración personalizados

```lua
local skynet = require "skynet"
require "skynet.debug"

-- Registrar callback personalizado de INFO
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- Registrar comando de depuración personalizado
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## Consola de depuración

`debug_console.lua` proporciona una interfaz telnet TCP, a la que se puede conectar para ejecutar comandos de depuración de forma interactiva.

### Inicio

```lua
-- Iniciar la consola de depuración en preload.lua
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### Conexión

```bash
telnet 127.0.0.1 8000
```

### Comandos de la consola

| Comando | Parámetros | Descripción |
|---|---|---|
| `help` | — | Listar todos los comandos |
| `list` | — | Listar todos los servicios en ejecución |
| `mem` | [timeout] | Consultar el estado de memoria de todos los servicios |
| `gc` | [timeout] | Activar GC en todos los servicios |
| `stat` | [timeout] | Consultar estadísticas de todos los servicios |
| `ping` | address | Detectar si un servicio está activo |
| `info` | address, ... | Obtener información personalizada del servicio |
| `exit` | address | Salida elegante del servicio especificado |
| `kill` | address | Terminar forzosamente el servicio especificado |
| `start` | name, ... | Iniciar un nuevo servicio Lua |
| `inject` | address, code | Inyectar y ejecutar código Lua en un servicio |

---

## Análisis de rendimiento con Profile

```lua
local profile = require "skynet.profile"
```

Proporciona medición de tiempo de CPU a nivel de corrutina mediante el módulo C `lua_profile.cpp`:

| Función | Descripción |
|---|---|
| `profile.start([co])` | Iniciar cronometraje de la corrutina (hilo actual por defecto) |
| `profile.stop([co])` | Detener cronometraje, devuelve el tiempo de CPU (segundos) |
| `profile.resume(co, ...)` | coroutine.resume con medición de tiempo |
| `profile.wrap(f)` | Crear un envoltorio de corrutina con medición de tiempo |

```lua
profile.start()
-- Ejecutar algunas operaciones intensivas de cálculo
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## Diferencias con el skynet original

- El conjunto de comandos del protocolo de depuración es básicamente idéntico
- El original tiene la función `signal` (interrumpir código Lua en bucle infinito), skynet-cpp aún no lo ha implementado
- El original tiene `skynet.trace()` para logs de seguimiento de mensajes, skynet-cpp aún no lo ha implementado

