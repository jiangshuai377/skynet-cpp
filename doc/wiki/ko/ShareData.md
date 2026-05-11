# ShareData
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 공유 데이터

---

```lua
local sharedata = require "sharedata"
```

비즈니스 로직을 여러 서비스로 분할한 후, 데이터 공유 방법은 가장 자주 직면하는 문제입니다. sharedata 모듈은 동일 프로세스 내 여러 서비스 간에 읽기 전용 구조화 데이터를 공유하는 데 사용되며, 대표적인 용도는 설정 테이블 배포입니다.

---

## 사용 방법

### 데이터 제공자

```lua
-- 공유 데이터 생성
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- 데이터 업데이트
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- 데이터 삭제
sharedata.delete("game_config")
```

### 데이터 소비자

```lua
-- 데이터 조회 (첫 조회 시 monitor 코루틴이 시작되어 업데이트를 감시)
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- 데이터 업데이트 후, 다음 접근 시 자동으로 새 버전을 가져옴
-- 딥카피 가져오기 (일회성 사용, 더 효율적)
local copy = sharedata.deepcopy("game_config")
```

---

## API

| 함수 | 설명 |
|---|---|
| `sharedata.new(name, value)` | 공유 데이터 생성. value는 임의의 Lua table 가능 |
| `sharedata.query(name)` | 공유 데이터 조회. 첫 조회 시 monitor 코루틴을 시작하여 업데이트를 자동 추적 |
| `sharedata.update(name, value)` | 공유 데이터 업데이트. 모든 보유자의 monitor가 알림을 받음 |
| `sharedata.delete(name)` | 공유 데이터 삭제 |
| `sharedata.flush()` | 로컬 캐시 지우기, 다음 query 시 서버에서 다시 가져옴 |
| `sharedata.deepcopy(name, ...)` | 데이터의 딥카피 가져오기. 추가 파라미터는 key 체인으로 하위 테이블 인덱싱 |

---

## 구현 아키텍처

```
sharedatad (유일 서비스)                   sharedata 클라이언트 (각 사용자)
├─ data_store[name]                    ├─ local_cache[name]
│   ├─ data (Lua table)                │   ├─ data
│   └─ version (증가 정수)              │   └─ version
└─ 명령:                               └─ monitor 코루틴:
    new/delete/query/update/monitor       sharedatad에 롱폴링하여 버전 변경 대기
```

**데이터 흐름**:
1. 서비스 A가 `sharedata.new("cfg", data)` 호출 → sharedatad가 데이터 저장
2. 서비스 B가 `sharedata.query("cfg")` 호출 → sharedatad에서 데이터 가져오기 + monitor 시작
3. 서비스 A가 `sharedata.update("cfg", new_data)` 호출 → sharedatad 업데이트 + 모든 monitor에 알림
4. 서비스 B의 monitor가 알림 수신 → 로컬 캐시 자동 업데이트

---

## 원본 skynet과의 차이점

- 원본 sharedata는 C 공유 메모리를 사용하여 다수의 Lua VM이 동일한 메모리 블록을 직접 읽을 수 있음. skynet-cpp는 메시지 전달 딥카피를 통해 데이터를 공유하며, 기능은 동등하지만 메모리를 공유하지 않음
- 원본에는 `sharetable` 모듈 (`lua_clonefunction` 기반)이 있으나, skynet-cpp는 미지원
- 원본에서 query한 객체는 일반 table처럼 읽을 수 있지만 (`__index` 메타메서드를 통해), skynet-cpp는 일반 table을 직접 반환
- 원본에는 STM / ShareMap 모듈이 있으나, skynet-cpp는 미지원

