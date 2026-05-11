# Socket
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> API de Socket do skynet-cpp

---

```lua
local socket = require "socket"
```

O skynet-cpp fornece um conjunto de APIs Lua em modo bloqueante para leitura e escrita TCP/UDP. O chamado modo bloqueante na verdade utiliza o mecanismo de coroutine do Lua. Quando você chama uma API de socket, o serviço pode ser suspenso (cedendo a fatia de tempo para outro processamento de negócio), e quando o resultado retorna via mensagem de socket, a coroutine continua a execução.

---

## API TCP

### Servidor

```lua
-- Escutar porta
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- Nova conexão aceita
    elseif event == "close" then
        -- Conexão fechada
    elseif event == "warning" then
        -- Alerta do buffer de envio
    end
end)

-- Definir callback de dados
socket.ondata(listener_id, function(conn_id, data)
    -- Dados recebidos
end)
```

- `socket.listen(host, port, handler)` — Escuta porta, handler recebe eventos accept/close/warning, retorna listener_id
- `socket.ondata(listener_id, handler)` — Define callback de dados `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — Envia dados na conexão do listener
- `socket.close_listener(listener_id)` — Fecha escuta
- `socket.pause(listener_id, conn_id)` — Pausa leitura da conexão (controle de fluxo)
- `socket.resume(listener_id, conn_id)` — Retoma leitura da conexão

### Cliente

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — Conecta ao host remoto, bloqueia até a conexão ser estabelecida ou falhar
- `socket.send(conn_id, data)` — Envia dados
- `socket.read(conn_id, sz)` — Lê sz bytes, bloqueia até os dados estarem prontos ou a conexão ser fechada
- `socket.readline(conn_id, sep)` — Lê até o separador (padrão `"\n"`), sem incluir o separador
- `socket.readall(conn_id)` — Lê todos os dados disponíveis
- `socket.close(conn_id)` — Fecha a conexão

---

## API UDP

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- Pacote UDP recebido
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — Cria socket UDP, callback recebe pacotes de dados
- `socket.udp_send(id, data, host, port)` — Envia pacote UDP

---

## socketdriver (módulo C)

`socket.lua` é um encapsulamento de coroutine sobre o módulo C de baixo nível `socketdriver`. As funções registradas pelo `socketdriver` incluem:

| Função | Descrição |
|---|---|
| `socketdriver.listen(host, port, backlog)` | Cria escuta TCP |
| `socketdriver.connect(host, port)` | Cria conexão TCP (assíncrona) |
| `socketdriver.send(id, data)` | Envia dados via connector |
| `socketdriver.write(listener_id, conn_id, data)` | Envia pela conexão do listener |
| `socketdriver.close(id, [conn_id])` | Fecha socket ou conexão |
| `socketdriver.pause(listener_id, conn_id)` | Pausa leitura da conexão |
| `socketdriver.resume(listener_id, conn_id)` | Retoma leitura da conexão |
| `socketdriver.udp(host, port)` | Cria socket UDP |
| `socketdriver.udp_send(id, data, host, port)` | Envia UDP |

---

## Diferenças em relação ao skynet original

- O original usa `socket.start(id)` para assumir o controle do socket (porque múltiplos serviços compartilham o socket id), no skynet-cpp o listener/connector é naturalmente vinculado ao serviço criador
- O original tem `socket.abandon` (transferência de controle), o skynet-cpp ainda não implementou
- O original tem `socket.lwrite` (fila de escrita de baixa prioridade), o skynet-cpp ainda não implementou
- O original tem `socket.block` (aguardar legibilidade), o skynet-cpp ainda não implementou

