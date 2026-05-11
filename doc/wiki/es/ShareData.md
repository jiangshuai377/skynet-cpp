# ShareData
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Datos compartidos de skynet-cpp

---

```lua
local sharedata = require "sharedata"
```

Cuando divides la lógica de negocio en múltiples servicios, cómo compartir datos es el problema más frecuente. El módulo sharedata se utiliza para compartir datos estructurados de solo lectura entre múltiples servicios dentro del mismo proceso, un uso típico es la distribución de tablas de configuración.

---

## Método de uso

### Proveedor de datos

```lua
-- Crear datos compartidos
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- Actualizar datos
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- Eliminar datos
sharedata.delete("game_config")
```

### Consumidor de datos

```lua
-- Consultar datos (la primera consulta inicia una corrutina monitor que vigila las actualizaciones)
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- Después de una actualización, el siguiente acceso obtiene automáticamente la nueva versión
-- Obtener una copia profunda (uso único, más eficiente)
local copy = sharedata.deepcopy("game_config")
```

---

## API

| Función | Descripción |
|---|---|
| `sharedata.new(name, value)` | Crear datos compartidos. value puede ser cualquier tabla Lua |
| `sharedata.query(name)` | Consultar datos compartidos. La primera consulta inicia una corrutina monitor que rastrea automáticamente las actualizaciones |
| `sharedata.update(name, value)` | Actualizar datos compartidos. Todos los monitores de los poseedores recibirán notificación |
| `sharedata.delete(name)` | Eliminar datos compartidos |
| `sharedata.flush()` | Limpiar la caché local, la próxima consulta obtendrá los datos del servidor nuevamente |
| `sharedata.deepcopy(name, ...)` | Obtener una copia profunda de los datos. Los parámetros adicionales sirven como cadena de claves para indexar subtablas |

---

## Arquitectura de implementación

```
sharedatad (servicio único)                   Cliente sharedata (cada usuario)
├─ data_store[name]                           ├─ local_cache[name]
│   ├─ data (tabla Lua)                       │   ├─ data
│   └─ version (entero incremental)           │   └─ version
└─ comandos:                                  └─ corrutina monitor:
    new/delete/query/update/monitor              long-polling a sharedatad esperando cambio de versión
```

**Flujo de datos**:
1. El servicio A llama a `sharedata.new("cfg", data)` → sharedatad almacena los datos
2. El servicio B llama a `sharedata.query("cfg")` → obtiene los datos de sharedatad + inicia el monitor
3. El servicio A llama a `sharedata.update("cfg", new_data)` → sharedatad actualiza + notifica a todos los monitores
4. El monitor del servicio B recibe la notificación → actualiza automáticamente la caché local

---

## Diferencias con el skynet original

- El sharedata original usa memoria compartida en C, múltiples VMs Lua pueden leer directamente el mismo bloque de memoria. skynet-cpp transmite copias profundas de datos mediante mensajes, funcionalmente equivalente pero sin compartir memoria
- El original tiene el módulo `sharetable` (basado en `lua_clonefunction`), skynet-cpp no lo soporta
- El objeto obtenido mediante query en el original puede leerse como una tabla normal (vía metamétodo `__index`), skynet-cpp devuelve directamente una tabla normal
- El original tiene los módulos STM / ShareMap, skynet-cpp no los soporta

