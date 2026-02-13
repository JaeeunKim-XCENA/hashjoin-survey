# ClickHouse Hash Join 구현 분석

## 1. 개요

ClickHouse는 세 가지 Hash Join 구현을 제공한다:
- **HashJoin**: 단일 스레드 build를 수행하는 기본 hash join (`src/Interpreters/HashJoin/HashJoin.cpp`)
- **ConcurrentHashJoin**: 병렬 build/probe를 지원하는 concurrent hash join (`src/Interpreters/ConcurrentHashJoin.cpp`)
- **GraceHashJoin**: 메모리 초과 시 디스크로 spill하는 external hash join (`src/Interpreters/GraceHashJoin.cpp`)

세 가지 모두 right table을 hash table에 build하고, left table로 probe하는 전통적인 build-then-probe 모델을 따른다.

---

## 2. Hash Table 구조

### 2.1 키 타입에 따른 자동 선택

ClickHouse의 가장 독특한 특징은 join key의 데이터 타입과 크기에 따라 **최적의 hash table variant를 자동 선택**하는 것이다. `chooseMethod()` 함수 (`HashJoin.cpp:304-377`)에서 다음과 같은 로직으로 hash table 타입을 결정한다:

| 조건 | 선택되는 타입 | Hash Table |
|------|-------------|------------|
| 단일 숫자 키, 1 byte | `key8` | `FixedHashMap<UInt8, Mapped>` |
| 단일 숫자 키, 2 bytes | `key16` | `FixedHashMap<UInt16, Mapped>` |
| 단일 숫자 키, 4 bytes | `key32` | `HashMap<UInt32, Mapped, HashCRC32<UInt32>>` |
| 단일 숫자 키, 8 bytes | `key64` | `HashMap<UInt64, Mapped, HashCRC32<UInt64>>` |
| 단일 숫자 키, 16 bytes | `keys128` | `HashMap<UInt128, Mapped, UInt128HashCRC32>` |
| 단일 숫자 키, 32 bytes | `keys256` | `HashMap<UInt256, Mapped, UInt256HashCRC32>` |
| 복합 fixed 키 ≤ 16 bytes | `keys128` | `HashMap<UInt128, ...>` |
| 복합 fixed 키 ≤ 32 bytes | `keys256` | `HashMap<UInt256, ...>` |
| 단일 String 키 | `key_string` | `HashMapWithSavedHash<string_view, Mapped>` |
| 단일 FixedString 키 | `key_fixed_string` | `HashMapWithSavedHash<string_view, Mapped>` |
| 그 외 | `hashed` | `HashMap<UInt128, Mapped, UInt128TrivialHash>` (직렬화 후 해싱) |

### 2.2 FixedHashMap — 직접 주소 매핑

`FixedHashMap<UInt8, Mapped>` / `FixedHashMap<UInt16, Mapped>` (`src/Common/HashTable/FixedHashMap.h`)는 키 값을 배열 인덱스로 직접 사용하는 direct-address table이다. UInt8의 경우 256개, UInt16의 경우 65536개의 슬롯을 가지며, 해싱 없이 O(1) 접근이 가능하다. `FixedHashMapCell` 구조체에서 `bool full` 필드로 슬롯 사용 여부를 추적한다 (`FixedHashMap.h:8-49`).

### 2.3 HashMap — Open Addressing

일반 `HashMap` (`src/Common/HashTable/HashMap.h`)은 `HashTable` (`src/Common/HashTable/HashTable.h`)을 기반으로 하며, **open addressing with linear probing** 방식을 사용한다. 키가 position-independent(memmoveable)해야 한다는 제약이 있으며, zero key는 별도로 저장한다 (`need_zero_value_storage = true`, `HashMap.h:99`). `HashMapCell` 구조체 (`HashMap.h:60-100`)가 key-value 쌍을 `PairNoInit<Key, Mapped>` 형태로 저장하며, CRC32 해시를 기본으로 사용한다.

### 2.4 HashMapWithSavedHash — 문자열 최적화

`HashMapWithSavedHash`는 문자열 키의 경우 해시 값을 셀 내에 캐싱하여, probe 시 전체 문자열 비교 전에 해시 값만 먼저 비교함으로써 성능을 개선한다.

### 2.5 TwoLevelHashMap — 버킷 분할 구조

`TwoLevelHashMap` (`src/Common/HashTable/TwoLevelHashMap.h`)은 `TwoLevelHashTable`을 상속하며, 내부적으로 `NUM_BUCKETS` 개의 sub-table(`impls[]`)로 구성된다. 각 sub-table은 독립적인 `HashMap`이다. 이 구조는 `ConcurrentHashJoin`에서 병렬 빌드 시 각 스레드가 독립적인 버킷 집합을 담당할 수 있게 한다.

### 2.6 MapsTemplate — Mapped 타입에 따른 분류

Hash table의 value 타입은 join strictness에 따라 세 가지로 나뉜다 (`HashJoin.h:353-357`):

```cpp
using MapsOne  = MapsTemplate<RowRef>;         // ANY, SEMI, ANTI — 키당 하나의 행
using MapsAll  = MapsTemplate<RowRefList>;      // ALL — 키당 여러 행 (linked list)
using MapsAsof = MapsTemplate<AsofRowRefs>;     // ASOF — 정렬된 탐색 구조
```

`MapsVariant = std::variant<MapsOne, MapsAll, MapsAsof>` 형태로 런타임에 선택된다. `joinDispatch.h`의 `MapGetter` 템플릿이 `(JoinKind, JoinStrictness)` 조합에 따라 어떤 Maps를 사용할지 결정한다 (`joinDispatch.h:26-64`).

---

## 3. Build Phase

### 3.1 기본 Build 프로세스

Build phase는 `HashJoin::addBlockToJoin()` (`HashJoin.cpp:636-852`)에서 수행된다.

1. **블록 준비**: 우측 테이블 블록을 `materializeColumnsFromRightBlock()`로 materialize하고, `filterColumnsPresentInSampleBlock()`으로 필요한 컬럼만 필터링
2. **키 추출**: `extractNestedColumnsAndNullMap()`으로 join 키 컬럼을 추출하고 NULL map을 분리
3. **데이터 저장**: 블록 컬럼들을 `data->columns`(linked list of `ScatteredColumns`)에 저장
4. **해시 테이블 삽입**: `joinDispatch()`를 통해 적절한 `HashJoinMethods::insertFromBlockImpl()`을 호출

### 3.2 삽입 전략 — Inserter 구조체

`Inserter` 구조체 (`HashJoinMethods.h:16-61`)는 세 가지 삽입 메서드를 제공한다:

- **`insertOne()`**: `MapsOne`용. `emplaceKey()`로 삽입하되, 이미 존재하면 건너뜀 (ANY 시맨틱). `anyTakeLastRow`가 true이면 기존 값을 덮어씀
- **`insertAll()`**: `MapsAll`용. 키가 이미 존재하면 `RowRefList`의 linked list에 Arena pool을 사용하여 새 노드를 추가 (`emplace_result.getMapped().insert({stored_columns_info, i}, pool)`)
- **`insertAsof()`**: `MapsAsof`용. ASOF 키에 대해 정렬된 lookup 구조(`AsofRowRefs`)에 삽입

### 3.3 키 정규화 — chooseMethod

Build 시작 시점에 `chooseMethod()` (`HashJoin.cpp:304-406`)가 키 컬럼을 분석하여 hash table 타입을 결정한다. 복합 키의 경우 고정 크기 바이트로 pack하여 `UInt128` 또는 `UInt256`에 매핑한다. 가변 길이이거나 너무 큰 키는 직렬화 후 cryptographic hash(`UInt128TrivialHash`)를 사용하는 `hashed` 타입으로 폴백한다.

### 3.4 ALL → RightAny 프로모션

`all_values_unique` 플래그로 right table에 중복 키가 없음이 확인되면, `ALL` strictness를 `RightAny`로 프로모션하여 성능을 개선한다 (`HashJoin.h:423-424`).

---

## 4. Probe Phase

### 4.1 Template-Based Dispatch

Probe는 `HashJoinMethods::joinBlockImpl()` (`HashJoinMethodsImpl.h:62-148`)에서 수행된다. `JoinFeatures` 템플릿 (`JoinFeatures.h:6-43`)이 컴파일 타임에 다음 플래그를 결정한다:

- `need_replication`: ALL join 등에서 left row를 복제해야 하는 경우
- `need_filter`: INNER/RIGHT join에서 매칭되지 않는 left row를 필터링
- `add_missing`: LEFT/FULL join에서 매칭되지 않는 right 컬럼에 기본값 추가
- `need_flags`: RIGHT/FULL join에서 right row 사용 여부를 추적

### 4.2 Probe 실행 흐름

1. `JoinOnKeyColumns` 생성: left 블록에서 join 키 컬럼 추출
2. `AddedColumns` 생성: right 테이블에서 추가할 컬럼 구조 준비
3. `switchJoinRightColumns()` 호출: hash table 타입별로 `joinRightColumns()`를 dispatch
4. 각 left row에 대해 `KeyGetter`로 해시를 계산하고 hash table에서 lookup
5. 매칭된 right row 참조(`RowRef`/`RowRefList`)를 `AddedColumns`에 추가
6. `HashJoinResult` 생성: filter, offsets_to_replicate, added columns를 포함한 결과 객체 반환

### 4.3 Scattered Block — 부분 처리

Probe 중 `max_joined_block_rows` 제한에 도달하면, 처리된 부분까지만 결과를 반환하고 나머지는 `ScatteredBlock`으로 분리하여 다음 호출에서 이어서 처리한다 (`HashJoinMethodsImpl.h:117-123`).

---

## 5. Parallelism (병렬 처리) ★

### 5.1 ConcurrentHashJoin 아키텍처

`ConcurrentHashJoin` (`src/Interpreters/ConcurrentHashJoin.cpp`)은 ClickHouse의 핵심 병렬 Hash Join 구현이다. 기본 `HashJoin`이 단일 스레드 build만 지원하는 것에 비해, `ConcurrentHashJoin`은 **build와 probe 모두를 병렬화**한다.

#### 핵심 설계 원리

```cpp
// ConcurrentHashJoin.h:87-92
struct InternalHashJoin {
    std::mutex mutex;
    std::unique_ptr<HashJoin> data;
    bool space_was_preallocated = false;
};

std::vector<std::shared_ptr<InternalHashJoin>> hash_joins;  // N개의 독립 인스턴스
```

N개의 독립적인 `HashJoin` 인스턴스를 생성하며, 각 인스턴스는 자체 mutex로 보호된다. `slots` 수는 2의 거듭제곱으로 올림 처리된다 (`toPowerOfTwo()`, 최대 256).

### 5.2 Two-Level Map 최적화

`ConcurrentHashJoin`은 각 `HashJoin` 인스턴스를 `use_two_level_maps = true`로 생성한다 (`ConcurrentHashJoin.cpp:187`). 이를 통해 **TwoLevelHashMap의 버킷 단위로 작업을 분할**한다.

핵심 아이디어 (`ConcurrentHashJoin.h:33-41`):
> 각 스레드가 TwoLevelHashMap의 서로 다른 버킷 집합을 담당한다. Thread #0은 버킷 {0, N, 2N, ...}, Thread #1은 {1, N+1, 2N+1, ...}을 소유한다. Build 완료 후 이 sub-map들을 O(1)에 병합할 수 있다.

### 5.3 병렬 Build Phase

```cpp
// ConcurrentHashJoin.cpp:247-299 — addBlockToJoin()
bool ConcurrentHashJoin::addBlockToJoin(const Block & right_block_, bool check_limits) {
    Block right_block = hash_joins[0]->data->materializeColumnsFromRightBlock(right_block_);
    auto dispatched_blocks = dispatchBlock(table_join->getOnlyClause().key_names_right, std::move(right_block));

    // dispatched_blocks를 각 hash_join 인스턴스에 삽입
    while (blocks_left > 0) {
        for (size_t i = 0; i < dispatched_blocks.size(); ++i) {
            std::unique_lock<std::mutex> lock(hash_join->mutex, std::try_to_lock);
            if (!lock.owns_lock()) continue;  // try_to_lock — 논블로킹
            hash_join->data->addBlockToJoin(block, std::move(selector), check_limits);
        }
    }
}
```

**비동기 스케줄링**: `std::try_to_lock`으로 mutex를 시도하고, 이미 잠긴 인스턴스는 건너뛰고 다음 루프에서 재시도한다. 이 방식은 한 스레드가 대기하지 않고 다른 슬롯에 삽입할 수 있게 한다.

### 5.4 Block Dispatch — ScatteredBlock

`dispatchBlock()` (`ConcurrentHashJoin.cpp:600-627`)은 입력 블록의 각 행을 해시하여 해당 `HashJoin` 인스턴스로 라우팅한다:

1. `selectDispatchBlock()`: 각 행의 join key를 해싱하고, `hash_table.getBucketFromHash(hash) & (num_shards - 1)`로 슬롯 번호 결정
2. **Zero-copy 최적화**: 컬럼이 클 때 실제 데이터 복사 대신 인덱스 목록(`ScatteredBlock::Indexes`)만 생성 (`scatterBlocksWithSelector()`). 작은 컬럼은 물리적으로 scatter (`scatterBlocksByCopying()`)

### 5.5 Build Phase 완료 — Map 병합

`onBuildPhaseFinish()` (`ConcurrentHashJoin.cpp:662-834`)에서 TwoLevelHashMap 사용 시:

1. **버킷 병합**: 각 slot의 TwoLevelHashMap에서 해당 slot이 소유한 버킷들을 slot 0으로 이동 (O(1) swap)
   ```cpp
   lhs_map.impls[j] = std::move(rhs_map.impls[j]);  // bucket-level move
   ```
2. **컬럼 데이터 통합**: `getData(hash_joins[0])->columns.splice(...)` — linked list splice로 O(1) 이동
3. **Shared Map 복사**: 병합된 공통 map을 모든 slot에 공유 (`getData(hash_joins[i])->maps = getData(hash_joins[0])->maps`)
4. **UsedFlags 통합**: RIGHT/FULL JOIN용 사용 플래그도 merge
5. **Nullmap 통합**: RIGHT/FULL JOIN에서 NULL 키 행의 nullmap을 slot 0으로 재구성

### 5.6 병렬 Probe Phase

Probe 시 TwoLevelHashMap을 사용하는 경우, **블록 dispatch 없이 공통 hash map에 직접 probe**한다:

```cpp
// ConcurrentHashJoin.cpp:373-386
JoinResultPtr ConcurrentHashJoin::joinBlock(Block block) {
    if (hash_joins[0]->data->twoLevelMapIsUsed())
        dispatched_blocks.emplace_back(std::move(block));  // 단일 블록 — dispatch 불필요
    else
        dispatched_blocks = dispatchBlock(...);  // fallback: per-slot dispatch
}
```

TwoLevelHashMap 경우 probe 시 블록을 분할하지 않아도 되므로, 일반 `HashJoin`과 동일한 성능으로 여러 스레드에서 동시 read가 가능하다.

### 5.7 병렬 파괴

Hash table 파괴도 병렬로 수행된다 (`ConcurrentHashJoin.cpp:213-238`). 각 스레드가 자신이 소유한 버킷만 `clearAndShrink()`하여 대규모 해시 테이블의 파괴 지연을 최소화한다.

### 5.8 통계 기반 사전 할당

`reserveSpaceInHashMaps()` (`ConcurrentHashJoin.cpp:103-130`)에서 이전 쿼리 통계(`HashTablesStatistics`)를 활용하여 각 slot의 소유 버킷에 대해 예상 크기만큼 공간을 사전 할당한다.

---

## 6. Partitioning 전략 — Grace Hash Join

### 6.1 3단계 처리

`GraceHashJoin` (`src/Interpreters/GraceHashJoin.cpp`)은 메모리가 부족할 때 디스크로 spill하는 external hash join이다. 3단계로 동작한다 (`GraceHashJoin.h:22-43`):

1. **Build (Right Table 적재)**: 각 입력 블록을 해시하여 bucket 0은 in-memory `HashJoin`에, 나머지는 디스크의 `FileBucket`에 기록
2. **Probe (Left Table 처리)**: 마찬가지로 left 블록을 해시 분배. Bucket 0은 즉시 in-memory join, 나머지는 디스크에 기록
3. **Delayed Processing**: 미처리 버킷을 순차적으로 디스크에서 읽어 in-memory `HashJoin`으로 build → probe → non-joined 처리

### 6.2 동적 Rehash

`addBlockToJoinImpl()` (`GraceHashJoin.cpp:698-764`)에서 in-memory `HashJoin`의 크기가 `sizeLimits`를 초과하면:

1. `rehashBuckets()` 호출 — 버킷 수를 2배로 증가 (`GraceHashJoin.cpp:361-386`)
2. 기존 in-memory 데이터를 `releaseJoinedBlocks()`로 추출
3. 새 버킷 수 기준으로 re-scatter하여 해당 버킷의 데이터만 새 `HashJoin`에 적재
4. 최대 버킷 수(`max_num_buckets`) 초과 시 예외 발생

### 6.3 FileBucket 구조

`FileBucket` (`GraceHashJoin.cpp:115-221`)은 left/right 각각의 `TemporaryBlockStreamHolder`를 가지며, 독립 mutex로 보호된다. `tryAddLeftBlock()`/`tryAddRightBlock()`은 `try_to_lock`을 사용하여 non-blocking 삽입을 시도하고, 실패 시 `retryForEach()`가 랜덤 순서로 다른 버킷을 시도한다 (`GraceHashJoin.cpp:226-249`).

### 6.4 CROSS / ASOF 미지원

Grace Hash Join은 `isSupported()` (`GraceHashJoin.cpp:301-306`)에서 ASOF, CROSS join을 명시적으로 제외한다. INNER, LEFT, RIGHT, FULL만 지원하며, 단일 disjunct(`oneDisjunct()`) 조건만 허용한다.

---

## 7. Memory Management

### 7.1 Block 축소 (Shrink to Fit)

`shrinkStoredBlocksToFit()` (`HashJoin.cpp:854-930`)은 메모리 사용이 `max_bytes_in_join`의 50%를 초과하거나 쿼리 전체 메모리 사용 증가가 50%를 넘으면, 저장된 모든 블록을 `cloneResized()`로 축소한다.

### 7.2 Arena Pool

`RightTableData` 내부의 `Arena pool` (`HashJoin.h:402`)은 `RowRefList`의 linked list 노드를 할당하는 데 사용된다. Arena는 일괄 할당/해제되어 개별 `new`/`delete`보다 효율적이다.

### 7.3 Cross Join 외부 저장

Cross join에서 메모리 제한 초과 시 `TemporaryDataOnDisk`에 right 블록을 기록한다 (`HashJoin.cpp:704-714`). 압축(`block_to_save.compress()`)도 특정 크기 이상에서 적용된다.

### 7.4 Grace Hash Join의 디스크 Spill

`GraceHashJoin`은 `TemporaryDataOnDiskScope`를 통해 임시 파일을 관리하며, 압축(`temporaryFilesCodec()`)과 버퍼 크기(`temporaryFilesBufferSize()`)를 설정에서 제어한다 (`GraceHashJoin.cpp:269-274`).

---

## 8. Join Types 지원

### 8.1 지원되는 Join 종류

ClickHouse는 다음 join 타입을 지원한다 (`HashJoin.h:43-67`):

| JoinKind | JoinStrictness | 설명 |
|----------|---------------|------|
| INNER | ALL | 표준 inner join, 모든 매칭 행 반환 |
| INNER | ANY | 키당 하나의 행만 매칭 |
| LEFT | ALL / ANY / SEMI / ANTI | 좌측 테이블 기준 |
| RIGHT | ALL / ANY / SEMI / ANTI | 우측 테이블 기준 |
| FULL | ALL / ANY | 양측 모든 행 |
| LEFT / INNER | ASOF | 비등가 조인 (nearest value) |
| CROSS | - | 카테시안 곱 |

### 8.2 Template Dispatch 메커니즘

`joinDispatch()` (`joinDispatch.h:102-127`)는 `static_for`로 `KINDS × STRICTNESSES` (4 × 6 = 24) 조합을 순회하며, 런타임의 `(kind, strictness)` 값에 매칭되는 컴파일 타임 템플릿을 호출한다. `MapGetter` 템플릿 (`joinDispatch.h:26-64`)이 각 조합에 대해 `MapsOne`/`MapsAll`/`MapsAsof` 중 어떤 것을 사용할지, `flagged`(사용 플래그 추적 필요 여부)를 결정한다.

### 8.3 JoinFeatures 컴파일 타임 특성

`JoinFeatures` (`JoinFeatures.h:6-43`)는 `(KIND, STRICTNESS, Map)` 조합에서 다음을 컴파일 타임에 결정한다:
- `need_replication`: ALL join이나 RIGHT ANY/SEMI에서 left row 복제 필요
- `need_filter`: INNER, RIGHT, LEFT SEMI/ANTI에서 필터링 필요
- `add_missing`: LEFT, FULL join에서 기본값 추가
- `need_flags`: RIGHT, FULL join에서 right row 사용 추적

### 8.4 ASOF Join

ASOF join은 등가 조건(equi-join) 키 외에 마지막 키 컬럼을 ASOF 키로 사용한다. `AsofRowRefs`에 정렬된 구조로 삽입되며, probe 시 inequality 조건(`<=`, `>=` 등)에 맞는 가장 가까운 값을 탐색한다 (`HashJoin.cpp:224-247`).

### 8.5 Non-Joined Rows (RIGHT/FULL)

RIGHT, FULL join에서 매칭되지 않은 right row는 `JoinUsedFlags`로 추적된다. Build 완료 후 `getNonJoinedBlocks()`가 사용 플래그를 스캔하여 미사용 right row를 반환한다.

---

## 9. Key References

### 소스 코드 경로

| 파일 | 주요 함수/클래스 |
|------|-----------------|
| `src/Interpreters/HashJoin/HashJoin.h` | `HashJoin` 클래스, `MapsTemplate`, `APPLY_FOR_JOIN_VARIANTS` 매크로, `RightTableData` |
| `src/Interpreters/HashJoin/HashJoin.cpp` | `chooseMethod()`, `addBlockToJoin()`, `shrinkStoredBlocksToFit()`, `dataMapInit()` |
| `src/Interpreters/ConcurrentHashJoin.h` | `ConcurrentHashJoin` 클래스, `InternalHashJoin` 구조체 |
| `src/Interpreters/ConcurrentHashJoin.cpp` | `addBlockToJoin()`, `joinBlock()`, `onBuildPhaseFinish()`, `dispatchBlock()`, `selectDispatchBlock()` |
| `src/Interpreters/GraceHashJoin.h` | `GraceHashJoin` 클래스, `FileBucket` |
| `src/Interpreters/GraceHashJoin.cpp` | `addBlockToJoinImpl()`, `rehashBuckets()`, `getDelayedBlocks()`, `DelayedBlocks::nextImpl()` |
| `src/Interpreters/HashJoin/HashJoinMethods.h` | `HashJoinMethods` 템플릿 클래스, `Inserter` 구조체 |
| `src/Interpreters/HashJoin/HashJoinMethodsImpl.h` | `insertFromBlockImpl()`, `joinBlockImpl()`, `insertFromBlockImplTypeCase()` |
| `src/Interpreters/HashJoin/JoinFeatures.h` | `JoinFeatures` 컴파일 타임 특성 |
| `src/Interpreters/joinDispatch.h` | `MapGetter`, `joinDispatch()`, `joinDispatchInit()` |
| `src/Common/HashTable/HashMap.h` | `HashMap`, `HashMapCell`, `PairNoInit` |
| `src/Common/HashTable/FixedHashMap.h` | `FixedHashMap`, `FixedHashMapCell` |
| `src/Common/HashTable/TwoLevelHashMap.h` | `TwoLevelHashMap`, `TwoLevelHashMapWithSavedHash` |
| `src/Common/HashTable/HashTable.h` | `HashTable` 기본 구현 (open addressing) |
| `src/Interpreters/HashJoin/ScatteredBlock.h` | `ScatteredBlock`, `Selector` (zero-copy block dispatch) |

### 핵심 설계 포인트 요약

1. **키 타입 기반 Hash Table 자동 선택**: `chooseMethod()`가 17가지 variant(single + two-level) 중 최적 선택
2. **템플릿 메타프로그래밍**: `(JoinKind × JoinStrictness × MapsType)` 조합의 컴파일 타임 dispatch로 런타임 분기 최소화
3. **TwoLevelHashMap 기반 병렬화**: 버킷 단위 소유권 분할 → 병렬 build → O(1) 병합 → probe 시 블록 분할 불필요
4. **Grace Hash Join**: 동적 rehash로 메모리 적응형 spill, 랜덤 순서 flush로 contention 감소
5. **Zero-copy ScatteredBlock**: 블록 dispatch 시 물리적 복사 대신 인덱스 셀렉터만 생성하여 메모리 효율 극대화
