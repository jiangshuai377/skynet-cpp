# GateServer
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Template de serviço de gateway do skynet-cpp

---

O serviço de gateway (GateServer) é a camada de acesso da aplicação. Sua funcionalidade básica é gerenciar conexões de clientes, dividir pacotes de dados completos e encaminhar para serviços de lógica.

O skynet-cpp fornece um template genérico em `lualib/gateserver.lua`.

---

## Modo de uso

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- Novo cliente conectado
end

function handler.disconnect(conn_id)
    -- Cliente desconectado
end

function handler.message(conn_id, data)
    -- Pacote de dados de negócio completo recebido (sem cabeçalho de comprimento)
end

function handler.open(source, conf)
    -- Gate abre porta de escuta
end

gateserver.start(handler)
```

Nota: `gateserver.start` chama internamente `skynet.start`.

---

## Callbacks do Handler

| Callback | Assinatura | Descrição |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | Chamado quando novo cliente é aceito |
| `disconnect` | `(conn_id)` | Chamado quando conexão é desconectada |
| `message` | `(conn_id, data)` | Pacote de negócio completo (fragmentado pelo netpack) chegou |
| `error` | `(conn_id, msg)` | Exceção de conexão |
| `warning` | `(conn_id, bytes)` | Alerta quando buffer de envio ultrapassa 1M |
| `open` | `(source, conf)` | Chamado quando porta de escuta é aberta |

---

## Protocolo de fragmentação de pacotes

Cada pacote = **cabeçalho de comprimento de 2 bytes big-endian** + **conteúdo dos dados**

Um único pacote de dados não pode exceder 65535 bytes. Se a lógica de negócio precisa transmitir blocos de dados maiores, resolva no protocolo de camada superior.

### API netpack

```lua
local netpack = require "netpack"
```

| Função | Descrição |
|---|---|
| `netpack.pack(data)` | Empacota dados (adiciona cabeçalho de comprimento de 2 bytes), retorna string emoldurada |
| `netpack.unpack(buffer, offset)` | Extrai um frame completo do buffer, retorna (next_offset, payload) |
| `netpack.filter(buffer, new_data)` | Mescla novos dados e extrai todos os frames completos |
| `netpack.tostring(msg, sz)` | Converte lightuserdata para Lua string |

---

## Comandos de controle

Outros serviços podem enviar os seguintes comandos ao gate via protocolo lua:

```lua
-- Abrir escuta
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- Enviar dados com cabeçalho de comprimento
skynet.call(gate, "lua", "SEND", conn_id, data)

-- Enviar dados brutos (sem cabeçalho de comprimento)
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- Fechar conexão
skynet.call(gate, "lua", "CLOSE", conn_id)

-- Expulsar conexão
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## Diferenças em relação ao skynet original

- O gateserver original está em `lualib/snax/gateserver.lua`, o skynet-cpp está em `lualib/gateserver.lua`
- O original tem `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` para controlar a recepção de mensagens, no skynet-cpp as conexões recebem mensagens por padrão
- O callback message original passa ponteiro C e comprimento `(fd, msg, sz)`, o skynet-cpp passa Lua string `(conn_id, data)`
- O original não pode ser misturado com a biblioteca socket no mesmo serviço, o skynet-cpp igualmente

