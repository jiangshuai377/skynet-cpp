# Build
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf` ; le dépôt runtime garde seulement les outils minimaux verify/package/package smoke/Linux coverage smoke, tandis que full coverage, perf, Docker DB, soak et comparaison native vivent dans la couche parente `testa/tools`. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Guide de compilation de skynet-cpp

---

## Obtenir le code source

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## Dépendances

Toutes les dépendances de skynet-cpp sont incluses dans le répertoire `3rdparty/`, aucune installation supplémentaire n'est nécessaire :

| Dépendance | Version | Description |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | Bibliothèque IO asynchrone multiplateforme (sans Boost) |
| **moodycamel::ConcurrentQueue** | latest | File MPMC sans verrou haute performance |
| **Lua** | 5.5.0 (version modifiée skynet) | VM Lua avec codecache |

---

## Outils de compilation

### Windows (recommandé)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+ (inclus avec VS2022)

### Linux

- **GCC** 12+ ou **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## Compilation

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

Ou en utilisant le CMake intégré à VS2022 :

```bat
"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -S . -B build
"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build build --config Debug
```

### Linux / macOS

```bash
cd skynet-cpp
mkdir build && cd build
cmake ..
make -j$(nproc)
```

Après une compilation réussie, l'exécutable se trouve dans `build/Debug/skynet-cpp.exe` (Windows) ou `build/skynet-cpp` (Linux/macOS).

---

## Package de Release

Utilisez CMake install ou le script helper pour produire un paquet exécutable :

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

La racine par défaut est `dist/skynet-cpp/`, avec `bin/`, `lualib/`, `service/`, `examples/` et `doc/`. Lancez depuis la racine du paquet et définissez `SKYNET_PRELOAD` avec un chemin relatif au cwd comme `examples/preload.lua`.

---

## Exécution

```bash
cd build/Debug
./skynet-cpp
```

Au démarrage, skynet-cpp exécute automatiquement the configured preload script comme script d'entrée utilisateur.

---

## À propos de Lua

skynet-cpp est livré avec le code source de Lua 5.5.0, une version modifiée de skynet contenant le mécanisme de **codecache** — plusieurs VM Lua peuvent partager le bytecode compilé, économisant la mémoire et accélérant l'initialisation des VM. Voir [CodeCache](CodeCache.md) pour plus de détails.

---

## Différences avec le skynet original

| Aspect | Skynet original | skynet-cpp |
|---|---|---|
| Système de build | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| Plateforme | Linux (epoll) | Windows/Linux/macOS (Asio) |
| Allocation mémoire | jemalloc + malloc hook | Allocateur C++ standard |
| Version Lua | 5.4 | 5.5.0 |

