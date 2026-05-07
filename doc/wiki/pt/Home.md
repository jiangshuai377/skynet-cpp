# Wiki do skynet-cpp
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> **skynet-cpp** — Reimplementação do framework Actor [Skynet](https://github.com/cloudwu/skynet) em C++20 moderno

---

## Bem-vindo

skynet-cpp é um framework leve de servidor baseado no modelo Actor, cujo conceito de design e semântica de API são originários do [cloudwu/skynet](https://github.com/cloudwu/skynet). O framework mantém a abstração central do skynet — **cada serviço é um Actor independente que se comunica por mensagens assíncronas** — ao mesmo tempo que aproveita os recursos da linguagem C++ moderna e o ecossistema multiplataforma para oferecer segurança de tipos, gerenciamento de recursos RAII e independência de plataforma.

Se você não tem nenhum conhecimento sobre o skynet-cpp, pode começar lendo [GettingStarted](GettingStarted.md). Como o skynet-cpp em si não é complexo, recomenda-se também a leitura do código-fonte.

[Build](Build.md) o skynet-cpp é muito simples, compilar e experimentar é um ótimo começo. Se você deseja fazer desenvolvimento secundário por conta própria, pode começar entendendo o [Bootstrap](Bootstrap.md).

Embora o núcleo do skynet-cpp seja escrito em C++, para uso simples não é necessário ter conhecimento de C++. Você precisa entender como funciona o padrão Actor e dividir sua lógica de negócio em múltiplos serviços para trabalhar de forma colaborativa. Lua é a linguagem de desenvolvimento necessária — basta conhecer Lua para usar a [LuaAPI](LuaAPI.md) para realizar a comunicação e colaboração entre serviços. Quanto ao compartilhamento de dados entre serviços, além da passagem de mensagens, você também pode consultar [ShareData](ShareData.md).

Para fornecer serviços aos clientes, é necessário usar a API de [Socket](Socket.md), ou utilizar o modelo de [GateServer](GateServer.md) já implementado para resolver o problema de acesso de grande volume de clientes. Através do [SocketChannel](SocketChannel.md), é possível fazer o skynet-cpp agendar eventos de socket externos de forma assíncrona. O acesso a [serviços externos](ExternalService.md) como bancos de dados é melhor feito através do encapsulamento com SocketChannel.

As funcionalidades já fornecidas pelo skynet-cpp podem ser consultadas em [APIList](APIList.md).

---

## Índice de documentação

### Introdução

| Documento | Descrição |
|---|---|
| [GettingStarted](GettingStarted.md) | Conceitos do framework, modelo Actor, mecanismo de mensagens, início rápido |
| [Build](Build.md) | Passos de compilação (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Fluxo de inicialização: main.cpp → ActorSystem → preload |

### API principal

| Documento | Descrição |
|---|---|
| [LuaAPI](LuaAPI.md) | Referência completa da API skynet.lua |
| [Socket](Socket.md) | API de Socket TCP/UDP |
| [GateServer](GateServer.md) | Template de gateway TCP + netpack para fragmentação de pacotes |
| [SocketChannel](SocketChannel.md) | Multiplexação de conexões TCP |

### Cluster e distribuição

| Documento | Descrição |
|---|---|
| [Cluster](Cluster.md) | Cluster RPC entre nós |

### Dados e comunicação entre serviços

| Documento | Descrição |
|---|---|
| [ShareData](ShareData.md) | Dados somente leitura compartilhados |
| [CriticalSection](CriticalSection.md) | Fila de serialização de mensagens (evita pseudo-concorrência) |
| [Multicast](Multicast.md) | Mensagens de publicação/assinatura |

### Depuração e ferramentas

| Documento | Descrição |
|---|---|
| [DebugConsole](DebugConsole.md) | Console de depuração + protocolo de depuração |
| [CodeCache](CodeCache.md) | Mecanismo de cache de código Lua 5.5 |

### Serviços externos

| Documento | Descrição |
|---|---|
| [ExternalService](ExternalService.md) | Drivers Redis / MySQL / MongoDB |

### Referência

| Documento | Descrição |
|---|---|
| [APIList](APIList.md) | Tabela de referência rápida de todas as APIs dos módulos |

---

## Principais diferenças em relação ao skynet original

| Dimensão | Skynet original (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Linguagem** | Implementação em C puro | C++20 (RAII + `std::shared_ptr`) |
| **Plataforma** | Apenas Linux (epoll) | Multiplataforma (Asio: Windows/Linux/macOS) |
| **Segurança de tipos** | Mensagens `void*` | `std::any` + `msg.get<T>()` |
| **Primitivas de concorrência** | spinlock próprio | Fila lock-free `moodycamel::ConcurrentQueue` |
| **IO assíncrono** | Servidor de socket próprio | Asio + `steady_timer` |
| **Versão Lua** | Lua 5.4 | Lua 5.5.0 (com codecache) |
| **Sistema de build** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Modo harbor** | Suporta master/slave | Não suporta (apenas modo cluster) |
| **Snax** | Suporta | Não suporta |
| **Sproto** | Suporta | Não suporta |
| **DataCenter** | Suporta | Não suporta (obsoleto) |
| **ShareData** | Memória compartilhada em C | Cópia profunda por passagem de mensagens (funcionalidade equivalente) |
| **Drivers de banco de dados** | Contém módulos C | Implementação em Lua puro (BSON/SHA1 são todos em Lua puro) |

