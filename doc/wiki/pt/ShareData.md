# ShareData
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Dados compartilhados do skynet-cpp

---

```lua
local sharedata = require "sharedata"
```

Quando você divide a lógica de negócio em múltiplos serviços, como compartilhar dados é um dos problemas mais enfrentados. O módulo sharedata é usado para compartilhar dados estruturados somente leitura entre múltiplos serviços dentro do mesmo processo, sendo a distribuição de tabelas de configuração seu uso típico.

---

## Modo de uso

### Provedor de dados

```lua
-- Criar dados compartilhados
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- Atualizar dados
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- Excluir dados
sharedata.delete("game_config")
```

### Consumidor de dados

```lua
-- Consultar dados (a primeira consulta inicia uma corrotina monitor que monitora atualizações)
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- Após atualização dos dados, o próximo acesso obtém automaticamente a nova versão
-- Obter cópia profunda (uso único, mais eficiente)
local copy = sharedata.deepcopy("game_config")
```

---

## API

| Função | Descrição |
|---|---|
| `sharedata.new(name, value)` | Cria dados compartilhados. value pode ser qualquer table Lua |
| `sharedata.query(name)` | Consulta dados compartilhados. A primeira consulta inicia corrotina monitor, acompanhando atualizações automaticamente |
| `sharedata.update(name, value)` | Atualiza dados compartilhados. Todos os monitores dos detentores recebem notificação |
| `sharedata.delete(name)` | Exclui dados compartilhados |
| `sharedata.flush()` | Limpa cache local, na próxima query busca novamente do servidor |
| `sharedata.deepcopy(name, ...)` | Obtém cópia profunda dos dados. Parâmetros extras servem como cadeia de chaves para indexar sub-tabelas |

---

## Arquitetura de implementação

```
sharedatad (serviço único)                  cliente sharedata (cada utilizador)
├─ data_store[name]                         ├─ local_cache[name]
│   ├─ data (Lua table)                     │   ├─ data
│   └─ version (inteiro incremental)        │   └─ version
└─ comandos:                                └─ corrotina monitor:
    new/delete/query/update/monitor            long polling no sharedatad aguardando mudança de versão
```

**Fluxo de dados**:
1. Serviço A chama `sharedata.new("cfg", data)` → sharedatad armazena dados
2. Serviço B chama `sharedata.query("cfg")` → obtém dados do sharedatad + inicia monitor
3. Serviço A chama `sharedata.update("cfg", new_data)` → sharedatad atualiza + notifica todos os monitores
4. O monitor do serviço B recebe notificação → atualiza automaticamente o cache local

---

## Diferenças em relação ao skynet original

- O sharedata original usa memória compartilhada em C, múltiplas VMs Lua podem ler diretamente o mesmo bloco de memória. O skynet-cpp transmite dados por cópia profunda via mensagens, funcionalidade equivalente mas sem memória compartilhada
- O original tem o módulo `sharetable` (baseado em `lua_clonefunction`), o skynet-cpp não suporta
- O objeto obtido por query no original pode ser lido como uma table normal (via metamétodo `__index`), o skynet-cpp retorna diretamente uma table normal
- O original tem módulos STM / ShareMap, o skynet-cpp não suporta

