# Bootstrap

## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

## Resumen

La entrada C++ solo realiza el bootstrap mínimo: crea `ActorSystem`, inicia logger, lee variables de entorno, inicia el LuaActor preload y entra en el loop worker/IO/monitor. Launcher ya no está hard-codeado en C++; el preload lo inicia explícitamente con `skynet.newservice("launcher")`.

## Variables de Entorno

| Variable | Valor por defecto | Descripción |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Número de workers |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Ruta del script preload |

## Flujo de Arranque

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## Responsabilidades de Preload

El preload es la única entrada de orquestación de arranque. Normalmente:

- Llama `skynet.appendpath` / `skynet.prependpath` para rutas Lua.
- Llama `skynet.appendcpath` para rutas de módulos C.
- Llama `skynet.appendservicepath` para rutas de servicios.
- Inicia `launcher`.
- Inicia la aplicación, ejemplo, logic, stress o perf.

## Pathbase y Layout del Paquete

Los valores relativos de `SKYNET_PRELOAD` se resuelven desde el cwd del proceso. Los paquetes de release deben iniciarse desde la raíz instalada, con `bin/`, `lualib/`, `service/`, `examples/` y `doc/`; el preload por defecto es `examples/preload.lua`. Un preload normalmente imprime `skynet.getcwd()`, llama `skynet.setpathbase(".")` y luego todas las rutas relativas de `appendpath` / `appendservicepath` / `appendcpath` se resuelven desde `skynet.getpathbase()`. `setpathbase` no cambia el cwd del sistema ni afecta el IO de terceros.

## Modelo de Hilos

| Hilo | Cantidad | Responsabilidad |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | Extrae `ActorQueue` de global queue y despacha mensajes en batches ponderados |
| IO | 1 | Ejecuta `asio::io_context` para red y timers |
| Monitor | 1 | Detecta workers bloqueados demasiado tiempo en el mismo mensaje |

## Preload de Ejemplo

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## Entradas Relacionadas

- Ejemplo: `examples/preload.lua`
- Pruebas logic: `tests/logic/preload.lua`
- Pruebas stress: `tests/stress/preload.lua`
- Pruebas perf: `tests/perf/preload.lua`
