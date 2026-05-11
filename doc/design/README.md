# skynet-cpp Design Documents

Architecture and implementation design documents are maintained in eight languages.

| Language | Document |
| --- | --- |
| 中文 | [zh.md](zh.md) |
| English | [en.md](en.md) |
| Deutsch | [de.md](de.md) |
| Español | [es.md](es.md) |
| Français | [fr.md](fr.md) |
| 日本語 | [ja.md](ja.md) |
| 한국어 | [ko.md](ko.md) |
| Português | [pt.md](pt.md) |

The design docs reflect the current preload-based bootstrap, global Lua path configuration APIs, ActorQueue scheduling model, Lua callback reference cache, wakeup optimization, and the split logic/stress/perf test layout. The runtime repository keeps only minimal verification and package smoke tools; full coverage, performance, Docker DB, soak, and native comparison runners live in the parent best-practice project.
