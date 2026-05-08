# Bootstrap

## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

## Visão Geral

A entrada C++ faz apenas o bootstrap mínimo: cria `ActorSystem`, inicia logger, lê variáveis de ambiente, inicia o LuaActor preload e entra no loop worker/IO/monitor. Launcher não é mais hard-codeado em C++; o script preload o inicia explicitamente com `skynet.newservice("launcher")`.

## Variáveis de Ambiente

| Variável | Padrão | Descrição |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Quantidade de worker threads |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Caminho do script preload |

## Fluxo de Inicialização

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

## Responsabilidades do Preload

O preload é o único ponto de orquestração de inicialização. Normalmente ele:

- Chama `skynet.appendpath` / `skynet.prependpath` para Lua module paths.
- Chama `skynet.appendcpath` para C module paths.
- Chama `skynet.appendservicepath` para service search paths.
- Inicia `launcher`.
- Inicia aplicação, exemplo, logic, stress ou perf.

## Pathbase e Layout do Pacote

Valores relativos de `SKYNET_PRELOAD` são resolvidos a partir do cwd do processo. Pacotes de release devem ser iniciados da raiz instalada, com `bin/`, `lualib/`, `service/`, `examples/` e `doc/`; o preload padrão é `examples/preload.lua`. Um preload normalmente imprime `skynet.getcwd()`, chama `skynet.setpathbase(".")`, e depois todas as entradas relativas de `appendpath` / `appendservicepath` / `appendcpath` são resolvidas a partir de `skynet.getpathbase()`. `setpathbase` não altera o cwd do SO e não afeta IO de terceiros.

## Modelo de Threads

| Thread | Quantidade | Responsabilidade |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | Retira `ActorQueue` da global queue e despacha mensagens em batches ponderados |
| IO | 1 | Executa `asio::io_context` para rede e timers |
| Monitor | 1 | Detecta workers presos tempo demais na mesma mensagem |

## Exemplo de Preload

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

- Exemplo: `examples/preload.lua`
- Testes logic: `tests/logic/preload.lua`
- Testes stress: `tests/stress/preload.lua`
- Testes perf: `tests/perf/preload.lua`
