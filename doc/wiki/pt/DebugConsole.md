# DebugConsole
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Console de depuração e protocolo de depuração do skynet-cpp

---

## Protocolo de depuração

Cada serviço Lua registra automaticamente o protocolo `PTYPE_DEBUG`, com os seguintes comandos de depuração integrados:

| Comando | Descrição |
|---|---|
| `MEM` | Retorna o uso de memória da VM Lua atual (KB) |
| `GC` | Aciona coleta de lixo, relata mudanças de memória |
| `STAT` | Retorna contagem de tarefas, comprimento da fila de mensagens, estatísticas de CPU |
| `TASK` | Retorna informações de pilha das corrotinas de tarefas |
| `INFO` | Chama o callback `info_func` registrado pelo serviço para obter informações personalizadas |
| `EXIT` | Encerra o serviço de forma elegante |
| `PING` | Detecção de atividade (resposta imediata) |
| `RUN` | Injeta e executa um trecho de código Lua |

### Registrar comandos de depuração personalizados

```lua
local skynet = require "skynet"
require "skynet.debug"

-- Registrar callback INFO personalizado
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- Registrar comando de depuração personalizado
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## Console de depuração

`debug_console.lua` fornece uma interface TCP telnet para execução interativa de comandos de depuração após conexão.

### Inicialização

```lua
-- Iniciar console de depuração em preload.lua
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### Conexão

```bash
telnet 127.0.0.1 8000
```

### Comandos do console

| Comando | Parâmetros | Descrição |
|---|---|---|
| `help` | — | Lista todos os comandos |
| `list` | — | Lista todos os serviços em execução |
| `mem` | [timeout] | Consulta estado de memória de todos os serviços |
| `gc` | [timeout] | Aciona GC em todos os serviços |
| `stat` | [timeout] | Consulta informações estatísticas de todos os serviços |
| `ping` | address | Verifica se o serviço está ativo |
| `info` | address, ... | Obtém informações personalizadas do serviço |
| `exit` | address | Encerra o serviço especificado de forma elegante |
| `kill` | address | Termina forçadamente o serviço especificado |
| `start` | name, ... | Inicia novo serviço Lua |
| `inject` | address, code | Injeta código Lua no serviço para execução |

---

## Profile - Análise de desempenho

```lua
local profile = require "skynet.profile"
```

Temporização de CPU por corrotina fornecida pelo módulo C `lua_profile.cpp`:

| Função | Descrição |
|---|---|
| `profile.start([co])` | Inicia temporização da corrotina (padrão: thread atual) |
| `profile.stop([co])` | Para temporização, retorna tempo de CPU (segundos) |
| `profile.resume(co, ...)` | coroutine.resume com temporização |
| `profile.wrap(f)` | Cria wrapper de corrotina com temporização |

```lua
profile.start()
-- Executar operações intensivas de computação
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## Diferenças em relação ao skynet original

- Conjunto de comandos do protocolo de depuração basicamente idêntico
- O original tem funcionalidade `signal` (interromper código Lua em loop infinito), o skynet-cpp ainda não implementou
- O original tem `skynet.trace()` para log de rastreamento de mensagens, o skynet-cpp ainda não implementou

