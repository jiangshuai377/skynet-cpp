# Wiki de skynet-cpp
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> **skynet-cpp** — Reimplementación del framework Actor [Skynet](https://github.com/cloudwu/skynet) con C++20 moderno

---

## Bienvenido

skynet-cpp es un framework ligero de servidor basado en el modelo Actor, cuya filosofía de diseño y semántica de API provienen de [cloudwu/skynet](https://github.com/cloudwu/skynet). El framework mantiene la abstracción central de skynet —**cada servicio es un Actor independiente que se comunica mediante mensajes asíncronos**—, al mismo tiempo que aprovecha las características del C++ moderno y su ecosistema multiplataforma para proporcionar seguridad de tipos, gestión de recursos RAII e independencia de plataforma.

Si no conoces nada sobre skynet-cpp, puedes comenzar leyendo [GettingStarted](GettingStarted.md). Dado que skynet-cpp no es complejo en sí mismo, también se recomienda leer el código fuente.

[Compilar](Build.md) skynet-cpp es muy sencillo; compilarlo y probarlo es un buen comienzo. Si deseas realizar desarrollo secundario, puedes comenzar entendiendo el [Bootstrap](Bootstrap.md).

Aunque el núcleo de skynet-cpp está escrito en C++, no se requiere conocimiento de C++ para un uso básico. Necesitas entender cómo funciona el patrón Actor y dividir tu lógica de negocio en múltiples servicios que trabajen de forma coordinada. Lua es el lenguaje de desarrollo necesario; solo necesitas conocer Lua para utilizar la [LuaAPI](LuaAPI.md) y lograr la comunicación y colaboración entre servicios. Para compartir datos entre servicios, además de la transmisión por mensajes, también puedes consultar [ShareData](ShareData.md).

Para proporcionar servicios a los clientes, necesitas usar la API de [Socket](Socket.md), o utilizar la plantilla [GateServer](GateServer.md) ya implementada para resolver el problema de la conexión de un gran número de clientes. Mediante [SocketChannel](SocketChannel.md) puedes permitir que skynet-cpp gestione de forma asíncrona los eventos de sockets externos. Para acceder a [servicios externos](ExternalService.md) como bases de datos, lo mejor es encapsularlos mediante SocketChannel.

Las funcionalidades ya proporcionadas por skynet-cpp pueden consultarse en [APIList](APIList.md).

---

## Índice de documentación

### Inicio

| Documento | Descripción |
|---|---|
| [GettingStarted](GettingStarted.md) | Conceptos del framework, modelo Actor, mecanismo de mensajes, inicio rápido |
| [Build](Build.md) | Pasos de compilación (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Proceso de arranque: main.cpp → ActorSystem → preload |

### API principal

| Documento | Descripción |
|---|---|
| [LuaAPI](LuaAPI.md) | Referencia completa de la API de skynet.lua |
| [Socket](Socket.md) | API de Socket TCP/UDP |
| [GateServer](GateServer.md) | Plantilla de gateway TCP + empaquetado netpack |
| [SocketChannel](SocketChannel.md) | Multiplexación de conexiones TCP |

### Clúster y distribución

| Documento | Descripción |
|---|---|
| [Cluster](Cluster.md) | Clúster RPC entre nodos |

### Datos y comunicación entre servicios

| Documento | Descripción |
|---|---|
| [ShareData](ShareData.md) | Datos compartidos de solo lectura |
| [CriticalSection](CriticalSection.md) | Cola de serialización de mensajes (evitar pseudoconcurrencia) |
| [Multicast](Multicast.md) | Mensajes de publicación/suscripción |

### Depuración y herramientas

| Documento | Descripción |
|---|---|
| [DebugConsole](DebugConsole.md) | Consola de depuración + protocolo de depuración |
| [CodeCache](CodeCache.md) | Mecanismo de caché de código en Lua 5.5 |

### Servicios externos

| Documento | Descripción |
|---|---|
| [ExternalService](ExternalService.md) | Drivers de Redis / MySQL / MongoDB |

### Referencia

| Documento | Descripción |
|---|---|
| [APIList](APIList.md) | Tabla de referencia rápida de API de todos los módulos |

---

## Principales diferencias con el skynet original

| Dimensión | Skynet original (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Lenguaje** | Implementación en C puro | C++20 (RAII + `std::shared_ptr`) |
| **Plataforma** | Solo Linux (epoll) | Multiplataforma (Asio: Windows/Linux/macOS) |
| **Seguridad de tipos** | Mensajes `void*` | `std::any` + `msg.get<T>()` |
| **Primitivas de concurrencia** | Spinlock propio | Cola sin bloqueo `moodycamel::ConcurrentQueue` |
| **IO asíncrono** | Socket server propio | Asio + `steady_timer` |
| **Versión de Lua** | Lua 5.4 | Lua 5.5.0 (con codecache) |
| **Sistema de compilación** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Modo harbor** | Soporta master/slave | No soportado (solo modo cluster) |
| **Snax** | Soportado | No soportado |
| **Sproto** | Soportado | No soportado |
| **DataCenter** | Soportado | No soportado (obsoleto) |
| **ShareData** | Memoria compartida en C | Copia profunda por transmisión de mensajes (funcionalmente equivalente) |
| **Drivers de base de datos** | Incluye módulos en C | Implementación en Lua puro (BSON/SHA1 todo en Lua puro) |

