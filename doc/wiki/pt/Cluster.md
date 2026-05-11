# Cluster
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Cluster do skynet-cpp

---

```lua
local cluster = require "skynet.cluster"
```

O skynet-cpp implementa o modo cluster para suportar RPC entre nós. Cada nó é um processo skynet-cpp independente, e os nós se comunicam por mensagens através de conexões TCP.

---

## Início rápido

### Nó A: Escuta + Fornece serviço

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- Registrar nome para acesso remoto
    cluster.register("echo", echo)

    -- Carregar configuração do cluster
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Abrir porta de escuta
    cluster.open("127.0.0.1", 19999)
end)
```

### Nó B: Chamada remota

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Chamada RPC ao serviço echo do nó A
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- Consultar nome registrado
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| Função | Descrição |
|---|---|
| `cluster.call(node, addr, ...)` | Chamada RPC síncrona ao serviço do nó remoto. Bloqueia aguardando resposta |
| `cluster.send(node, addr, ...)` | Push assíncrono de mensagem ao nó remoto (sem resposta). Há risco de perda |
| `cluster.open(addr, port)` | Abre porta de escuta, aceita conexões de cluster de entrada |
| `cluster.reload(cfg)` | Recarrega configuração do cluster. cfg é uma tabela `{nodename = "host:port", ...}` |
| `cluster.register(name, addr)` | Registra nome de serviço local para acesso remoto via `@name`. addr padrão é o próprio serviço |
| `cluster.unregister(name)` | Cancela registro do nome |
| `cluster.query(node, name)` | Consulta endereço do serviço registrado via `cluster.register` no nó remoto |

### Formato de endereço

O segundo parâmetro `addr` de `cluster.call` pode ser:

- **Nome em string**: como `".echo"`, busca por esse nome no nó de destino
- **Nome com prefixo `@`**: como `"@echo"`, busca pelo nome registrado via `cluster.register`
- **Endereço numérico**: se você já conhece o handle do serviço remoto

---

## Arquitetura

O sistema cluster é composto por três serviços:

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ serviço local
  (gerenciador) (saída)               (entrada)         ↓
      ▲                                             resposta
      │                                                │
      └────────────────────── [TCP] ←──────────────────┘
```

| Serviço | Quantidade | Responsabilidade |
|---|---|---|
| `clusterd` | 1 por nó | Gerenciador central: configuração, ciclo de vida de sender/agent, registro de nomes, escuta |
| `clustersender` | 1 por nó remoto | Mantém conexão TCP ao nó remoto, envia solicitações via socketchannel |
| `clusteragent` | 1 por conexão | Processa conexões de entrada, analisa solicitações e despacha para serviços locais, retransmite respostas |

---

## Protocolo do cluster

O módulo C `cluster.core` implementa o protocolo de fio do cluster:

- **Formato do pacote**: Cabeçalho de comprimento de 2 bytes big-endian + carga útil
- **Pacote de solicitação**: Marcador de tipo + session + endereço de destino + mensagem serializada
- **Pacote de resposta**: session + sucesso/falha + mensagem serializada
- **Fragmentação de mensagens grandes**: Mensagens que excedem 32KB são automaticamente divididas em múltiplos segmentos para transmissão

---

## Ordem das mensagens

As solicitações entre clusters são, na maioria, ordenadas pela ordem de chamada (primeiro a enviar, primeiro a chegar). Porém, quando um único pacote excede 32KB, o pacote é fragmentado para transmissão, e pacotes grandes podem chegar depois dos pequenos.

Solicitações e respostas usam a mesma conexão TCP, com ordem garantida.

---

## Atualização de configuração

Recarregue a configuração via `cluster.reload(cfg)`. Se o endereço de um nó for alterado, novas solicitações após o reload serão enviadas para o novo endereço. Solicitações anteriores não concluídas ainda aguardam no endereço antigo.

É possível definir o endereço de um nó como `false` para marcá-lo como offline.

---

## Diferenças em relação ao skynet original

- O skynet-cpp **não suporta** modo master/slave (harbor), apenas cluster
- A configuração do cluster original é carregada por arquivo, o skynet-cpp passa via `cluster.reload(table)`
- O original tem `cluster.proxy(node, addr)` para criar proxy local, o skynet-cpp ainda não implementou
- O original tem `cluster.snax` para suportar serviços Snax remotos, o skynet-cpp não suporta Snax
- A configuração original suporta `__nowaiting = true`, o skynet-cpp ainda não implementou

