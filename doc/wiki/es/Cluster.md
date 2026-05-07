# Cluster
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`, con runners separados para coverage y perf Linux Docker. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Clúster de skynet-cpp

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp implementa el modo cluster para soportar RPC entre nodos. Cada nodo es un proceso skynet-cpp independiente, y los nodos se comunican entre sí mediante conexiones TCP para la transmisión de mensajes.

---

## Inicio rápido

### Nodo A: Escuchar + Proporcionar servicio

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- Registrar nombre para acceso remoto
    cluster.register("echo", echo)

    -- Cargar configuración del clúster
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Abrir puerto de escucha
    cluster.open("127.0.0.1", 19999)
end)
```

### Nodo B: Llamada remota

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Llamada RPC al servicio echo del nodo A
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- Consultar nombre registrado
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| Función | Descripción |
|---|---|
| `cluster.call(node, addr, ...)` | Llamada RPC síncrona al servicio de un nodo remoto. Bloquea esperando respuesta |
| `cluster.send(node, addr, ...)` | Envío asíncrono de mensaje al nodo remoto (sin respuesta). Riesgo de pérdida |
| `cluster.open(addr, port)` | Abrir puerto de escucha, aceptar conexiones entrantes del clúster |
| `cluster.reload(cfg)` | Recargar configuración del clúster. cfg es una tabla `{nodename = "host:port", ...}` |
| `cluster.register(name, addr)` | Registrar nombre de servicio local para acceso remoto vía `@name`. addr por defecto es el propio servicio |
| `cluster.unregister(name)` | Desregistrar un nombre registrado |
| `cluster.query(node, name)` | Consultar la dirección de un servicio registrado vía `cluster.register` en un nodo remoto |

### Formato de dirección

El segundo parámetro `addr` de `cluster.call` puede ser:

- **Nombre de cadena**: como `".echo"`, busca ese nombre en el nodo destino
- **Nombre con prefijo `@`**: como `"@echo"`, busca por nombre registrado vía `cluster.register`
- **Dirección numérica**: si ya conoces el handle del servicio remoto

---

## Arquitectura

El sistema cluster se compone de tres servicios:

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ servicio local
  (gestor)   (saliente)           (entrante)          ↓
      ▲                                          respuesta
      │                                              │
      └────────────────────── [TCP] ←─────────────────┘
```

| Servicio | Cantidad | Responsabilidad |
|---|---|---|
| `clusterd` | 1 por nodo | Gestor central: configuración, ciclo de vida de sender/agent, registro de nombres, escucha |
| `clustersender` | 1 por nodo remoto | Mantiene la conexión TCP al nodo remoto, envía solicitudes vía socketchannel |
| `clusteragent` | 1 por conexión | Maneja conexiones entrantes, analiza solicitudes y las distribuye a servicios locales, devuelve respuestas |

---

## Protocolo del clúster

El módulo C `cluster.core` implementa el protocolo de cable del clúster:

- **Formato de empaquetado**: 2 bytes de cabecera de longitud big-endian + carga útil
- **Paquete de solicitud**: Marcador de tipo + session + dirección destino + mensaje serializado
- **Paquete de respuesta**: session + éxito/fallo + mensaje serializado
- **Fragmentación de mensajes grandes**: Los mensajes que superan 32KB se dividen automáticamente en múltiples segmentos para la transmisión

---

## Orden de mensajes

Las solicitudes entre nodos del clúster se ordenan en su mayoría por orden de envío (primero enviado, primero recibido). Sin embargo, cuando un paquete individual supera 32KB, el paquete se fragmenta para la transmisión, y los paquetes grandes pueden llegar después de los pequeños.

Las solicitudes y respuestas utilizan la misma conexión TCP, por lo que el orden está garantizado.

---

## Actualización de configuración

Recarga la configuración mediante `cluster.reload(cfg)`. Si se modifica la dirección de un nodo, las nuevas solicitudes después del reload se enviarán a la nueva dirección. Las solicitudes pendientes anteriores seguirán esperando en la dirección antigua.

Se puede establecer la dirección de un nodo como `false` para marcar el nodo como fuera de línea.

---

## Diferencias con el skynet original

- skynet-cpp **no soporta** el modo master/slave (harbor), solo soporta cluster
- La configuración del cluster original se carga desde archivos, skynet-cpp la pasa mediante `cluster.reload(table)`
- El original tiene `cluster.proxy(node, addr)` para crear un proxy local, skynet-cpp aún no lo ha implementado
- El original tiene `cluster.snax` para soportar servicios Snax remotos, skynet-cpp no soporta Snax
- La configuración original soporta `__nowaiting = true`, skynet-cpp aún no lo ha implementado

