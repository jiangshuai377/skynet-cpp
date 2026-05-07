# Bootstrap

## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

## Überblick

Der C++ Einstieg führt nur ein minimales Bootstrap aus: `ActorSystem` erstellen, Logger starten, Umgebungsvariablen lesen, den Preload-LuaActor starten und danach die Worker/IO/Monitor-Schleife betreten. Der Launcher ist nicht mehr in C++ hart codiert; das Preload-Skript startet ihn explizit mit `skynet.newservice("launcher")`.

## Umgebungsvariablen

| Variable | Standard | Beschreibung |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Anzahl der Worker-Threads |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Pfad zum Preload-Skript |

## Startablauf

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## Aufgaben des Preload-Skripts

Preload ist der einzige Einstieg für die Start-Orchestrierung. Typische Aufgaben:

- `skynet.appendpath` / `skynet.prependpath` für Lua module paths.
- `skynet.appendcpath` für C module paths.
- `skynet.appendservicepath` für service search paths.
- `launcher` starten.
- Anwendung, Beispiel, Logic-, Stress- oder Perf-Einstieg starten.

## Thread-Modell

| Thread | Anzahl | Aufgabe |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | `ActorQueue` aus der global queue entnehmen und Nachrichten in gewichteten Batches dispatchen |
| IO | 1 | `asio::io_context` für Netzwerk-IO und Timer ausführen |
| Monitor | 1 | Worker erkennen, die zu lange an derselben Nachricht hängen |

## Beispiel-Preload

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## Verwandte Einstiege

- Beispiel: `examples/preload.lua`
- Logic-Tests: `tests/logic/preload.lua`
- Stress-Tests: `tests/stress/preload.lua`
- Performance-Tests: `tests/perf/preload.lua`
