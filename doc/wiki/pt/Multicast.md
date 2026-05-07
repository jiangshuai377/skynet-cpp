# Multicast
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Publicação/Assinatura do skynet-cpp

---

```lua
local multicast = require "skynet.multicast"
```

O módulo Multicast fornece um mecanismo de mensagens de publicação/assinatura baseado em canais dentro do mesmo processo.

---

## Modo de uso

### Publicador

```lua
local multicast = require "skynet.multicast"

-- Criar novo canal
local mc = multicast.new()
print("channel id:", mc.channel)

-- Publicar mensagem (fire-and-forget)
mc:publish("event_name", { data = 123 })

-- Excluir canal
mc:delete()
```

### Assinante

```lua
local multicast = require "skynet.multicast"

-- Usar ID de canal existente
local mc = multicast.new({ channel = channel_id })

-- Definir callback de recebimento
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- Assinar
mc:subscribe()

-- Cancelar assinatura
mc:unsubscribe()
```

---

## API

| Método | Descrição |
|---|---|
| `multicast.new(opts)` | Cria objeto de canal. opts pode conter `{channel=id}` para usar canal existente |
| `mc:subscribe()` | Assina o serviço atual neste canal |
| `mc:unsubscribe()` | Cancela assinatura |
| `mc:publish(...)` | Publica mensagem para todos os assinantes |
| `mc:delete()` | Exclui este canal |
| `mc.dispatch` | Define como função de callback para receber mensagens publicadas |

---

## Arquitetura de implementação

| Componente | Descrição |
|---|---|
| Serviço `multicastd` | Serviço único, gerencia alocação de IDs de canal, lista de assinantes, difusão de mensagens |
| Cliente `multicast.lua` | Registra tipo de protocolo `PTYPE_MULTICAST`, fornece API orientada a objetos |

Fluxo de publicação de mensagens:
1. O publicador chama `mc:publish(...)`
2. A mensagem é enviada ao serviço `multicastd`
3. `multicastd` percorre a lista de assinantes e envia mensagem `PTYPE_MULTICAST` para cada assinante
4. O callback dispatch do assinante é acionado

---

## Diferenças em relação ao skynet original

- API basicamente idêntica
- O original suporta multicast entre nós (distribuído via datacenter), o skynet-cpp suporta apenas dentro do mesmo processo

