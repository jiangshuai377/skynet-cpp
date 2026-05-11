# LuaAPI
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Referência da API Lua para serviços skynet

---

```lua
local skynet = require "skynet"
```

Cada serviço do skynet-cpp precisa importar o módulo `skynet`. Este módulo não pode ser usado fora do framework skynet-cpp.

---

## Endereço do serviço

Cada serviço possui um endereço numérico de 32 bits (handle).

- `skynet.self()` — Retorna o endereço do serviço atual
- `skynet.address(addr)` — Converte o endereço em string legível (formato `:xxxxxxxx`)
- `skynet.register(name)` — Registra um alias para o serviço atual (nomes que começam com `.` são nomes locais)
- `skynet.name(name, handle)` — Registra um alias para o serviço com o handle especificado
- `skynet.localname(name)` — Consulta o endereço correspondente ao nome local (não bloqueante)

Todos os parâmetros de API que aceitam endereços de serviço também podem receber aliases em string.

---

## Despacho e resposta de mensagens

### skynet.dispatch(type, func)

Registra a função de tratamento para um tipo específico de mensagem. Uso mais comum:

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

Registra uma nova categoria de mensagem. class precisa fornecer os campos `name`, `id`, `pack`, `unpack`.

### skynet.ret(msg, sz)

Responde a mensagem à fonte da solicitação atual. Pode ser chamado apenas uma vez dentro da mesma corrotina de tratamento de mensagem.

### skynet.retpack(...)

Atalho para `skynet.ret(skynet.pack(...))`.

### skynet.response([packfunc])

Gera um closure de resposta atrasada, que pode ser chamado em outra corrotina no futuro.

```lua
local resp = skynet.response()
-- Depois, chamar em outro lugar:
resp(true, result1, result2)   -- resposta normal
resp(false)                     -- lança exceção para o solicitante
```

---

## Envio de mensagens e chamadas remotas

### skynet.send(addr, typename, ...)

Envia uma mensagem do tipo typename para addr. API não bloqueante, a mensagem é empacotada pela função pack.

### skynet.call(addr, typename, ...)

Envia uma solicitação para addr e bloqueia aguardando a resposta. A resposta é desempacotada por unpack e retornada. **Nota**: `skynet.call` bloqueia apenas a corrotina atual, o serviço ainda pode responder a outras mensagens.

### skynet.rawsend(addr, typename, msg, sz)

Envio bruto, sem empacotamento pela função pack.

### skynet.rawcall(addr, typename, msg, sz)

Chamada RPC bruta, sem pack/unpack.

### skynet.redirect(addr, source, typename, session, ...)

Envia mensagem para addr fingindo ser o endereço source.

---

## Relógio e threads

A precisão do relógio interno é de 1/100 de segundo (centissegundo).

- `skynet.now()` — Retorna o tempo decorrido desde o início do processo (centissegundos)
- `skynet.starttime()` — Retorna o tempo UTC de início do processo (segundos)
- `skynet.time()` — Retorna o tempo UTC atual (segundos, precisão de 10ms)

### skynet.sleep(ti)

Suspende a corrotina atual por ti centissegundos. Retorna `"BREAK"` se for acordada por `wakeup`.

### skynet.yield()

Equivalente a `skynet.sleep(0)`. Cede o controle da CPU.

### skynet.timeout(ti, func)

Após ti centissegundos, executa func em uma nova corrotina. API não bloqueante.

### skynet.fork(func, ...)

Inicia uma nova corrotina para executar func. Mais eficiente que `timeout(0, ...)` (não passa pelo temporizador).

### skynet.wait(token)

Suspende a corrotina atual, aguardando ser acordada por `wakeup`. O token padrão é `coroutine.running()`.

### skynet.wakeup(token)

Acorda a corrotina suspensa por `sleep` ou `wait`.

---

## Inicialização e encerramento do serviço

### skynet.start(func)

Registra a função de inicialização do serviço. **Deve ser chamada obrigatoriamente**, é o ponto de entrada do serviço.

### skynet.exit()

Encerra o serviço atual. O código subsequente não será executado, e corrotinas suspensas serão interrompidas.

### skynet.newservice(name, ...)

Inicia um novo serviço Lua. API bloqueante, aguarda o retorno da função `start` do serviço iniciado.

### skynet.uniqueservice(name, ...)

Inicia um serviço único. Se já estiver iniciado, retorna o endereço existente.

### skynet.queryservice(name)

Consulta o endereço de um serviço único. Se ainda não estiver iniciado, aguarda.

## Path Configuration

These APIs are normally called from the preload script. Each argument is a plain directory path; the runtime normalizes `/`, `\`, duplicate separators, and trailing separators, then expands Lua/C module or service search rules internally. Newly created LuaActors inherit the current global path snapshot.

- `skynet.appendpath(path)` — Append a Lua module directory, expanded to `path/?.lua` and `path/?/init.lua`.
- `skynet.prependpath(path)` — Prepend a Lua module directory.
- `skynet.appendcpath(path)` — Append a C module directory, expanded to the platform `.dll` or `.so` search pattern.
- `skynet.appendservicepath(path)` — Append a service script directory, expanded to `path/?.lua`.
- `skynet.getpath()` — Return the current `{ path, cpath, service_path }` snapshot.
- `skynet.getcwd()` — Return the process current working directory for preload logging and path debugging.
- `skynet.setpathbase(path)` — Set the relative base used by path APIs without changing the OS cwd.
- `skynet.getpathbase()` — Return the current pathbase.
- `skynet.readfile(path)` / `skynet.writefile(path, data, append)` — Controlled file read/write helpers that resolve paths from pathbase.
- `skynet.systemstat()` — Return process-level runtime stats such as actor count, global queue backlog, and worker count.

---

## Serialização

- `skynet.pack(...)` — Serializa valores Lua para `(lightuserdata, size)`
- `skynet.unpack(msg, sz)` — Desserializa para valores Lua
- `skynet.packstring(...)` — Serializa para Lua string
- `skynet.tostring(msg, sz)` — Converte lightuserdata para Lua string
- `skynet.trash(msg, sz)` — Libera buffer lightuserdata

Tipos suportados: string, boolean, number, lightuserdata, table (sem metatable).

---

## Log

### skynet.error(...)

Concatena os parâmetros e envia ao serviço logger. Formato de saída: `[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## Consulta de estado

- `skynet.info_func(func)` — Registra função de consulta de estado interno, chamada pelo protocolo de depuração
- `skynet.stat(what)` — Consulta estado interno do serviço: `"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## Outros

- `skynet.getenv(key)` — Lê variável de ambiente
- `skynet.setenv(key, value)` — Define variável de ambiente (não sobrescrevível)
- `skynet.genid()` — Gera session único
- `skynet.harbor(addr)` — Sempre retorna 0 (skynet-cpp não suporta harbor)

---

## Diferenças em relação ao skynet original

- `skynet.harbor()` sempre retorna 0
- Não suporta `skynet.forward_type` e `skynet.filter` (encaminhamento avançado de mensagens)
- `skynet.memlimit` deve ser chamado antes de `start`
- Variáveis de ambiente são passadas via `ActorSystem` em vez de arquivo de configuração


