# CriticalSection
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Fila de serialização de mensagens do skynet-cpp

---

```lua
local queue = require "skynet.queue"
```

Dentro do processamento de uma mensagem em um mesmo serviço skynet-cpp, se uma API bloqueante for chamada (como `skynet.call`), ela será suspensa. Durante a suspensão, este serviço pode responder a outras mensagens. Isso pode facilmente causar problemas de sequenciamento, exigindo tratamento cuidadoso.

Em outras palavras, uma vez que seu processamento de mensagem envolve solicitações externas, a mensagem que chegou primeiro pode não ser a primeira a terminar o processamento. Após cada chamada bloqueante, o estado interno do serviço pode não ser consistente com o estado antes da chamada.

O módulo `skynet.queue` pode ajudá-lo a evitar a complexidade causada pela pseudo-concorrência.

---

## Modo de uso

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs é uma fila de execução

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 entra na seção crítica
end

function CMD.foo()
    cs(func2)  -- func2 entra na seção crítica
end
```

Se você usar a fila `cs`, `func1` e `func2` não serão interrompidas mutuamente durante a execução.

Se o serviço receber múltiplas mensagens `foobar` ou `foo`, uma mensagem só será processada após a conclusão da anterior, mesmo que `func1` ou `func2` contenham chamadas bloqueantes como `skynet.call`.

---

## Reentrância

Chamar cs novamente dentro da função func1 é legal (não causa deadlock):

```lua
local function func2()
    -- passo 3
end

local function func1()
    -- passo 2
    cs(func2)
    -- passo 4
end

function CMD.foobar()
    -- passo 1
    cs(func1)
    -- passo 5
end
```

Cada vez que uma mensagem foobar é recebida, o fluxo do programa será executado na ordem passo 1 → 2 → 3 → 4 → 5.

---

## Princípio de implementação

A queue implementa agendamento FIFO através do seguinte mecanismo:

- `current_thread`: Registra a corrotina que atualmente detém o bloqueio
- Contagem de referência `ref`: Suporta chamadas aninhadas da mesma corrotina (reentrância)
- Fila de espera `thread_queue`: Novas solicitações são enfileiradas no final da fila
- Utiliza `skynet.wait()` / `skynet.wakeup()` para implementar suspensão e ativação entre corrotinas

---

## Diferenças em relação ao skynet original

- API completamente idêntica
- Implementação idêntica (baseada em skynet.wait/wakeup)

