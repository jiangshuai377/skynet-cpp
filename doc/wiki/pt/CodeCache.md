# CodeCache
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`, com runners separados para coverage e perf Linux Docker. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Mecanismo de cache de código Lua 5.5

---

## Visão geral

O skynet-cpp usa a versão modificada Lua 5.5.0 do skynet, que inclui o mecanismo de **codecache**. Este mecanismo permite que múltiplas VMs Lua (ou seja, múltiplos serviços) compartilhem protótipos de funções Lua compilados (Proto), proporcionando:

1. **Economia de memória**: O mesmo script é compilado em bytecode apenas uma vez
2. **Aceleração de inicialização**: VMs subsequentes que carregam o mesmo script reutilizam diretamente, sem necessidade de reanálise

---

## Como funciona

Quando um serviço Lua carrega um script via `loadfile`:

1. **Primeiro carregamento**: Compila normalmente e armazena o protótipo de função compilado no cache global
2. **Carregamentos subsequentes**: Clona diretamente o protótipo de função do cache, pulando a etapa de compilação

Extensões de API C chave:
- `lua_clonefunction(L, proto)` — Cria novo closure a partir do protótipo compartilhado
- `lua_sharefunction(L, index)` — Adiciona protótipo de função ao pool compartilhado

---

## Uso no skynet-cpp

Em `loader.lua`, o codecache está desativado por padrão (`cache.mode("OFF")`), porque:

- Cada `LuaActor` do skynet-cpp possui seu próprio `lua_State` independente, com `_ENV` completamente isolado entre VMs
- Se o codecache estiver ativado, múltiplas VMs compartilham o mesmo Proto compilado, mas o ambiente global (`_ENV`) de cada VM é diferente. Quando o Proto referencia funções globais como `require`, `_ENV` pode apontar para a VM errada
- Com o codecache desativado, cada VM compila scripts independentemente, e `_ENV` aponta corretamente

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- Desativar cache compartilhado
```

---

## Controle manual

Se você tem certeza de que certos scripts de funções puras não dependem de `_ENV`, pode ativar seletivamente o cache:

```lua
local cache = require "cache"

-- Consultar modo atual
local mode = cache.mode()

-- Definir modo: ON / OFF
cache.mode("ON")   -- Ativar cache compartilhado
cache.mode("OFF")  -- Desativar cache compartilhado
```

---

## Diferenças em relação ao skynet original

- O skynet original ativa o codecache por padrão, o skynet-cpp desativa por padrão
- O original obtém a interface de controle via `require "skynet.codecache"`, o skynet-cpp controla via `require "cache"`
- O original fornece `codecache.clear()` para limpar o cache, o skynet-cpp ainda não suporta

