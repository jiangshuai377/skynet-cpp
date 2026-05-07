# GettingStarted
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`, con runners separados para coverage y perf Linux Docker. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Guía de inicio de skynet-cpp

---

## Framework

skynet-cpp es un framework ligero de servidor basado en el modelo Actor. Puedes entenderlo como un sistema operativo simple, capaz de gestionar miles de máquinas virtuales Lua y hacerlas trabajar en paralelo. Cada máquina virtual Lua puede recibir y procesar mensajes enviados por otras máquinas virtuales, así como enviar mensajes a otras.

skynet-cpp tiene incorporada la gestión de datos de red externa y temporizadores, convirtiéndolos en mensajes consistentes que se entregan a cada servicio.

### Relación con el skynet original

La filosofía de diseño y la semántica de la API de skynet-cpp provienen completamente de [cloudwu/skynet](https://github.com/cloudwu/skynet), pero el framework subyacente ha sido reimplementado con C++20. Para los desarrolladores Lua, el uso de la API es básicamente el mismo que en el skynet original.

---

## Servicio (Service)

Los servicios de skynet-cpp se escriben en Lua. Solo necesitas colocar archivos `.lua` que cumplan con la especificación en rutas accesibles por skynet-cpp para que puedan ser iniciados por otros servicios. Cada servicio posee una dirección única de 32 bits (handle), asignada por el framework.

Cada servicio tiene tres fases de ejecución:

1. **Fase de carga**: Se carga y ejecuta el archivo fuente del servicio. En esta fase **no se puede** llamar a ninguna API bloqueante.
2. **Fase de inicialización**: Se ejecuta la función de inicialización registrada mediante `skynet.start(func)`. En esta fase se puede llamar a cualquier API de skynet. El `skynet.newservice` que inició este servicio esperará a que la inicialización se complete.
3. **Fase de trabajo**: Una vez completada la inicialización, el servicio que ha registrado funciones de manejo de mensajes comienza a responder mensajes.

```lua
local skynet = require "skynet"

-- Fase de carga: configurar variables a nivel de módulo
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- Fase de inicialización: registrar distribución de mensajes
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## Mensaje (Message)

Cada mensaje de skynet-cpp consta de los siguientes elementos:

1. **session**: Identificador único generado por el servicio que inicia la solicitud. El servicio que responde lo devuelve en la respuesta, y el emisor lo usa para emparejar solicitudes con respuestas. Un session de 0 indica que no se requiere respuesta (envío unidireccional).
2. **source**: Dirección del servicio de origen del mensaje (handle de 32 bits).
3. **type**: Categoría del mensaje. El más común es `"lua"`, utilizado para la comunicación entre servicios Lua.
4. **message + size**: Contenido del mensaje (puntero C + longitud), generado por funciones de serialización.

### Tipos de mensaje

| Tipo | Nombre | Uso |
|---|---|---|
| 0 | `text` | Mensaje de texto plano |
| 1 | `response` | Respuesta RPC |
| 6 | `socket` | Evento de red |
| 7 | `error` | Notificación de error |
| 10 | `lua` | Mensaje serializado Lua (el más común) |

---

## Planificación de corrutinas

Desde el nivel inferior, cada servicio es simplemente un procesador de mensajes. Sin embargo, a nivel de aplicación, funciona utilizando las coroutines de Lua.

Cuando tu servicio envía una solicitud a otro servicio (`skynet.call`), la corrutina actual se suspende. Cuando la otra parte recibe la solicitud y responde, el framework localiza la corrutina suspendida, le pasa la información de respuesta y continúa el flujo de negocio que estaba pendiente. Desde la perspectiva del usuario, es como si un hilo independiente estuviera procesando la tarea.

**Nota sobre reentrada**: Un servicio puede seguir procesando otros mensajes mientras un flujo de negocio está suspendido. Por lo tanto, el estado interno del servicio obtenido antes de `skynet.call` puede haber cambiado cuando retorna. El proceso de ejecución entre dos llamadas a API bloqueantes es atómico. Se puede utilizar [CriticalSection](CriticalSection.md) para reducir la complejidad derivada de la pseudoconcurrencia.

---

## Red

skynet-cpp tiene incorporada la capa de red, que encapsula la funcionalidad TCP y UDP. No se recomienda usar módulos que interactúen directamente con la API de red del sistema dentro de los servicios, ya que si se bloquean por IO de red, afectan a todo el hilo de trabajo.

Usando la API de [Socket](Socket.md) incorporada en skynet-cpp, se puede liberar completamente la capacidad de procesamiento del CPU durante los bloqueos de IO de red.

Se recomienda usar el servicio gateway [GateServer](GateServer.md) para gestionar la conexión de clientes.

---

## Servicios externos

skynet-cpp proporciona módulos de driver para [Redis](ExternalService.md#redis-驱动), [MySQL](ExternalService.md#mysql-驱动) y [MongoDB](ExternalService.md#mongodb-驱动). Estos módulos de driver están basados en [SocketChannel](SocketChannel.md) y funcionan perfectamente con skynet-cpp.

---

## Clúster

skynet-cpp implementa el modo cluster para soportar RPC entre nodos. Véase [Cluster](Cluster.md) para más detalles.

A diferencia del skynet original, skynet-cpp **no soporta** el modo master/slave (modo harbor), se recomienda utilizar exclusivamente el modo cluster.

---

## Diferencias con el skynet original

- **No soporta** el modo master/slave (harbor)
- **No soporta** el framework Snax
- **No soporta** el protocolo Sproto
- **No soporta** DataCenter (obsoleto)
- ShareData utiliza copia profunda por transmisión de mensajes, en lugar de memoria compartida en C
- Utiliza Lua 5.5.0 (el original utiliza Lua 5.4)
- Los drivers de base de datos (BSON/SHA1) están completamente implementados en Lua puro

