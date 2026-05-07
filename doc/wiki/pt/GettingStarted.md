# GettingStarted
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Guia de introdução ao skynet-cpp

---

## Framework

skynet-cpp é um framework leve de servidor baseado no modelo Actor. Você pode entendê-lo como um sistema operacional simples que pode agendar milhares de máquinas virtuais Lua, permitindo que trabalhem em paralelo. Cada máquina virtual Lua pode receber e processar mensagens enviadas por outras máquinas virtuais, além de enviar mensagens para elas.

O skynet-cpp possui gerenciamento integrado de entrada de dados de rede externa e temporizadores, convertendo-os em mensagens consistentes que são entregues a cada serviço.

### Relação com o skynet original

O conceito de design e a semântica de API do skynet-cpp são completamente originários do [cloudwu/skynet](https://github.com/cloudwu/skynet), mas o framework subjacente foi reimplementado usando C++20. Para desenvolvedores Lua, o uso da API é basicamente idêntico ao skynet original.

---

## Serviço (Service)

Os serviços do skynet-cpp são escritos em Lua. Basta colocar arquivos `.lua` que sigam a especificação em um caminho que o skynet-cpp possa encontrar para que possam ser iniciados por outros serviços. Cada serviço possui um endereço único de 32 bits (handle), atribuído pelo framework.

Cada serviço tem três fases de execução:

1. **Fase de carregamento**: O arquivo-fonte do serviço é carregado e executado. Nesta fase, **não é possível** chamar nenhuma API bloqueante.
2. **Fase de inicialização**: A função de inicialização registrada por `skynet.start(func)` é executada. Nesta fase, qualquer API do skynet pode ser chamada. O `skynet.newservice` que iniciou este serviço aguarda a conclusão da inicialização.
3. **Fase de trabalho**: Após a conclusão da inicialização, o serviço que registrou funções de tratamento de mensagens começa a responder às mensagens.

```lua
local skynet = require "skynet"

-- Fase de carregamento: definir variáveis no nível do módulo
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- Fase de inicialização: registrar despacho de mensagens
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## Mensagem (Message)

Cada mensagem do skynet-cpp é composta pelos seguintes elementos:

1. **session**: Um identificador único gerado pelo serviço que inicia a solicitação. O respondente retorna o session na resposta, e o remetente o utiliza para corresponder solicitação e resposta. Um session igual a 0 indica que não é necessária resposta (push unidirecional).
2. **source**: O endereço do serviço de origem da mensagem (handle de 32 bits).
3. **type**: Categoria da mensagem. A mais usada é `"lua"`, para comunicação entre serviços Lua.
4. **message + size**: Conteúdo da mensagem (ponteiro C + comprimento), gerado pela função de serialização.

### Tipos de mensagem

| Tipo | Nome | Uso |
|---|---|---|
| 0 | `text` | Mensagem de texto puro |
| 1 | `response` | Resposta RPC |
| 6 | `socket` | Evento de rede |
| 7 | `error` | Notificação de erro |
| 10 | `lua` | Mensagem serializada Lua (mais comum) |

---

## Agendamento de corrotinas

Do ponto de vista de baixo nível, cada serviço é um processador de mensagens. Mas na camada de aplicação, ele utiliza as coroutines do Lua.

Quando seu serviço envia uma solicitação a outro serviço (`skynet.call`), a corrotina atual é suspensa. Após o outro lado receber a solicitação e responder, o framework encontra a corrotina suspensa, passa as informações de resposta e continua o fluxo de negócios inacabado. Do ponto de vista do usuário, é mais como uma thread independente processando o negócio.

**Atenção à reentrada**: Um serviço pode continuar processando outras mensagens enquanto um fluxo de negócios está suspenso. Portanto, o estado interno do serviço obtido antes de `skynet.call` pode já ter mudado quando retornar. O processo de execução entre duas chamadas de API bloqueantes é atômico. Você pode usar [CriticalSection](CriticalSection.md) para reduzir a complexidade causada pela pseudo-concorrência.

---

## Rede

O skynet-cpp possui uma camada de rede integrada que encapsula funcionalidades TCP e UDP. Não é recomendado usar módulos que interagem diretamente com APIs de rede do sistema nos serviços, pois uma vez bloqueado por IO de rede, toda a thread de trabalho é afetada.

Usando a API de [Socket](Socket.md) integrada do skynet-cpp, é possível liberar completamente a capacidade de processamento da CPU quando o IO de rede está bloqueado.

Recomenda-se usar o serviço de gateway [GateServer](GateServer.md) para gerenciar o acesso dos clientes.

---

## Serviços externos

O skynet-cpp fornece módulos de driver para [Redis](ExternalService.md#redis-驱动), [MySQL](ExternalService.md#mysql-驱动) e [MongoDB](ExternalService.md#mongodb-驱动). Todos esses módulos de driver são baseados no [SocketChannel](SocketChannel.md) e funcionam bem em conjunto com o skynet-cpp.

---

## Cluster

O skynet-cpp implementa o modo cluster para suportar RPC entre nós. Veja [Cluster](Cluster.md) para detalhes.

Diferentemente do skynet original, o skynet-cpp **não suporta** o modo master/slave (modo harbor), recomendando-se o uso exclusivo do modo cluster.

---

## Diferenças em relação ao skynet original

- **Não suporta** modo master/slave (harbor)
- **Não suporta** framework Snax
- **Não suporta** protocolo Sproto
- **Não suporta** DataCenter (obsoleto)
- ShareData usa cópia profunda por passagem de mensagens, em vez de memória compartilhada em C
- Usa Lua 5.5.0 (o original usa Lua 5.4)
- Drivers de banco de dados (BSON/SHA1) são todos implementação em Lua puro

