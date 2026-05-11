# SocketChannel
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Multiplexação de conexões Socket do skynet-cpp

---

```lua
local socketchannel = require "skynet.socketchannel"
```

O padrão de solicitação-resposta é um dos padrões mais comuns ao interagir com serviços externos. O socketchannel fornece um encapsulamento de alto nível, suportando dois designs de protocolo:

1. **Modo sequencial (Order Mode)**: Cada solicitação corresponde a uma resposta, com ordem garantida pelo TCP (ex: Redis)
2. **Modo de sessão (Session Mode)**: Cada solicitação carrega um session único, e a resposta traz de volta o session para correspondência (ex: MongoDB)

---

## Criar Channel

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- Parâmetros opcionais a seguir:
    response = dispatch_func,   -- Se fornecido, entra no modo Session
    auth = auth_func,           -- Callback de autenticação após conexão estabelecida
    nodelay = true,             -- TCP_NODELAY
}
```

O socket channel não estabelece conexão imediatamente na criação. A conexão é adiada até o primeiro `request`. Após desconexão, o próximo `request` reconecta automaticamente.

---

## Modo sequencial (Order Mode)

Adequado para protocolos como Redis onde cada solicitação tem exatamente uma resposta em ordem:

```lua
local resp = channel:request(req_string, function(sock)
    -- sock é o objeto de leitura passado pelo channel
    local line = sock:readline()
    return true, line  -- Primeiro valor de retorno: sucesso; segundo: conteúdo da resposta
end)
```

O primeiro valor de retorno da função response é boolean:
- `true`: Análise do protocolo normal
- `false`: Erro no protocolo, a conexão será desconectada, request lança error

---

## Modo de sessão (Session Mode)

Adequado para protocolos como MongoDB que podem responder fora de ordem. Requer uma função `response` global fornecida na criação:

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- Analisar pacote de resposta
        local session = ...  -- Extrair session da resposta
        local ok = true
        local data = ...     -- Analisar dados da resposta
        return session, ok, data
    end,
}

-- Enviar solicitação, passando session em vez de função response
local resp = channel:request(req_string, session_id)
```

---

## Autenticação

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- Chamado automaticamente após conexão estabelecida
        -- Pode fazer AUTH / SELECT etc.
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

A função auth é executada imediatamente após cada conexão estabelecida. Se a autenticação falhar, lance error na auth.

---

## Outras APIs

| Método | Descrição |
|---|---|
| `channel:connect(once)` | Conexão explícita. once=true significa tentar apenas uma vez, falha lança erro |
| `channel:close()` | Fecha o channel, acorda todos os requests em espera |
| `channel:changehost(host, port)` | Altera endereço remoto e reconecta |
| `channel:read(sz)` | Lê sz bytes do channel |
| `channel:readline(sep)` | Lê do channel por separador |
| `channel:response(func)` | Sem enviar solicitação, apenas aguarda receber uma resposta (usado em pub/sub) |

---

## Diferenças em relação ao skynet original

- API basicamente idêntica
- O original tem parâmetro `padding` e escrita de baixa prioridade (`socket.lwrite`), o skynet-cpp ainda não implementou
- O original tem endereço `backup` de reserva (projetado para clusters mongo), o skynet-cpp ainda não implementou
- O original tem callback `overload` de sobrecarga, o skynet-cpp ainda não implementou

