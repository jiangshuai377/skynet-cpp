# CodeCache
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`, con runners separados para coverage y perf Linux Docker. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Mecanismo de caché de código en Lua 5.5

---

## Descripción general

skynet-cpp utiliza una versión modificada de Lua 5.5.0 de skynet, que incluye el mecanismo de **codecache**. Este mecanismo permite que múltiples VMs de Lua (es decir, múltiples servicios) compartan prototipos de funciones Lua compilados (Proto), logrando así:

1. **Ahorro de memoria**: El mismo script solo se compila una vez como bytecode
2. **Arranque más rápido**: Las VMs posteriores que cargan el mismo script lo reutilizan directamente, sin necesidad de analizar nuevamente

---

## Principio de funcionamiento

Cuando un servicio Lua carga un script mediante `loadfile`:

1. **Primera carga**: Se compila normalmente y el prototipo de función compilado se almacena en la caché global
2. **Cargas posteriores**: Se clona directamente el prototipo de función desde la caché, saltando el paso de compilación

APIs C clave extendidas:
- `lua_clonefunction(L, proto)` — Crear un nuevo closure a partir de un prototipo compartido
- `lua_sharefunction(L, index)` — Añadir un prototipo de función al pool compartido

---

## Uso en skynet-cpp

En `loader.lua`, el codecache está desactivado por defecto (`cache.mode("OFF")`), por las siguientes razones:

- Cada `LuaActor` de skynet-cpp posee su propio `lua_State` independiente, y el `_ENV` de cada VM está completamente aislado
- Si el codecache estuviera activado, múltiples VMs compartirían el mismo Proto compilado, pero el entorno global (`_ENV`) de cada VM es diferente. Cuando los Protos hacen referencia a funciones globales como `require`, el `_ENV` podría apuntar a la VM incorrecta
- Con el codecache desactivado, cada VM compila los scripts de forma independiente y el `_ENV` apunta correctamente

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- Deshabilitar la caché compartida
```

---

## Control manual

Si confirmas que ciertos scripts de funciones puras no dependen de `_ENV`, puedes activar selectivamente la caché:

```lua
local cache = require "cache"

-- Consultar el modo actual
local mode = cache.mode()

-- Configurar modo: ON / OFF
cache.mode("ON")   -- Activar caché compartida
cache.mode("OFF")  -- Desactivar caché compartida
```

---

## Diferencias con el skynet original

- El skynet original activa el codecache por defecto, skynet-cpp lo desactiva por defecto
- El original obtiene la interfaz de control mediante `require "skynet.codecache"`, skynet-cpp lo controla mediante `require "cache"`
- El original proporciona `codecache.clear()` para limpiar la caché, skynet-cpp aún no lo soporta

