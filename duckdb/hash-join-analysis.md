# DuckDB Hash Join 구현 분석

## 1. Hash Table 구조

DuckDB의 Hash Join은 **open addressing + linear probing** 방식의 hash table을 사용한다. 핵심 구조체는 `ht_entry_t` (`src/include/duckdb/execution/ht_entry.hpp`)로, 64비트 값 하나에 **salt(상위 16비트)**와 **pointer(하위 48비트)**를 함께 저장한다.

```
[SALT: 16 bits][POINTER: 48 bits]
```

- **SALT_MASK**: `0xFFFF000000000000` — hash 값의 상위 16비트를 salt로 사용
- **POINTER_MASK**: `0x0000FFFFFFFFFFFF` — 하위 48비트로 실제 row data의 포인터를 저장

Salt는 linear probing 시 불필요한 key 비교를 줄이기 위한 "빠른 필터" 역할을 한다. `ht_entry_t::ExtractSalt()` 함수가 hash 값에서 salt를 추출한다. Hash table의 capacity가 `USE_SALT_THRESHOLD` (8192)보다 클 때만 salt 비교를 활성화하여, CPU 캐시에 들어가는 작은 테이블에서는 불필요한 salt 연산을 건너뛴다 (`JoinHashTable::UseSalt()`, `join_hashtable.cpp:337`).

Hash table의 전체 메모리 레이아웃은 두 부분으로 구성된다:

1. **Pointer Table (hash_map)**: `ht_entry_t` 배열. 각 엔트리가 salt+pointer를 저장한다. Capacity는 항상 2의 거듭제곱이며, `bitmask = capacity - 1`로 모듈러 연산을 AND 연산으로 대체한다.
2. **Data Collection**: `TupleDataCollection`에 실제 row 데이터를 저장. 각 row의 레이아웃은 `[SERIALIZED ROW][NEXT POINTER]` 형태다 (`join_hashtable.hpp:48-58`). 동일 hash bucket에 여러 row가 있으면 NEXT POINTER로 체인을 구성한다.

**Load Factor**: in-memory join의 기본 load factor는 `2.0` (hash table이 25-50% 차있는 상태), external join 시 `1.5`로 줄여서 collision을 감소시킨다 (`join_hashtable.hpp:434-436`).

### Perfect Hash Join

단일 정수형 equality 조건의 inner join이고, build 측 key 범위가 `MAX_BUILD_SIZE` (1,048,576) 이하이며 중복이 없을 때 **Perfect Hash Join**을 사용한다 (`perfect_hash_join_executor.cpp:66-127`, `PerfectHashJoinExecutor::CanDoPerfectHashJoin()`). 이 경우 hash table 대신 key 값을 직접 배열 인덱스로 사용하여 O(1) 직접 접근이 가능하다. 결과는 DictionaryVector로 구성하여 probe 시 데이터 복사를 최소화한다.

## 2. Build Phase

Build phase는 RHS(Right-Hand Side) 데이터를 hash table에 적재하는 과정이다.

### 2.1 Sink: 데이터 수집

각 스레드는 독립적인 **thread-local `JoinHashTable`** (`HashJoinLocalSinkState::hash_table`)을 생성하여 데이터를 수집한다 (`physical_hash_join.cpp:372-409`). `PhysicalHashJoin::Sink()` 함수에서:

1. `ExpressionExecutor`로 join key를 추출한다
2. `JoinHashTable::Build()` (`join_hashtable.cpp:383-456`)를 호출하여 row를 `sink_collection` (RadixPartitionedTupleData)에 append한다
3. 이때 각 row는 `[join keys | payload columns | (found match bool) | hash]` 형태로 직렬화된다

NULL 처리: `PrepareKeys()` (`join_hashtable.cpp:458-485`)에서 NULL key를 가진 row를 필터링한다. 단, RIGHT/FULL OUTER join에서는 NULL key row도 유지한다.

### 2.2 Combine: Thread-local HT 병합

`PhysicalHashJoin::Combine()` (`physical_hash_join.cpp:512-531`)에서 각 스레드의 local hash table을 global sink state의 `local_hash_tables` 벡터에 추가한다. Lock을 잡고 벡터에 push하는 방식이다.

### 2.3 Finalize: Pointer Table 구축

Finalize는 수집된 데이터를 기반으로 실제 probing 가능한 hash table을 구축한다. 두 단계로 진행된다:

**단계 1: Pointer Table 초기화 (`HashJoinTableInitEvent`)**
- `AllocatePointerTable()` (`join_hashtable.cpp:740-776`)에서 capacity를 결정하고 메모리를 할당한다
- `InitializePointerTable()` (`join_hashtable.cpp:778-781`)에서 모든 엔트리를 0으로 초기화한다
- 병렬화: 여러 스레드가 각각 `ht_entry_t` 배열의 다른 영역을 memset한다

**단계 2: Hash 삽입 (`HashJoinFinalizeEvent`)**
- `Finalize()` (`join_hashtable.cpp:783-804`)에서 data_collection을 순회하며 각 row의 hash를 읽어 pointer table에 삽입한다
- `InsertHashesLoop()` (`join_hashtable.cpp:598-723`)가 핵심 루프: hash에서 bitmask로 위치를 계산하고, salt 비교 후 빈 슬롯 또는 같은 salt의 슬롯을 찾아 삽입한다
- 동일 key의 row는 NEXT POINTER로 체인을 형성한다
- 병렬 삽입 시 `atomic<ht_entry_t>`에 대해 `compare_exchange_strong/weak`를 사용한다 (`InsertRowToEntry()`, `join_hashtable.cpp:498-533`)

## 3. Probe Phase

Probe phase는 LHS(Left-Hand Side) 데이터가 들어올 때마다 hash table을 조회하는 과정이다. DuckDB의 vectorized execution 모델에 따라 **STANDARD_VECTOR_SIZE (2048) 튜플 단위**로 처리된다.

### 3.1 Probe 흐름

`PhysicalHashJoin::ExecuteInternal()` (`physical_hash_join.cpp:1207-1265`)에서:

1. Probe 키를 추출하고 hash를 계산한다
2. `JoinHashTable::Probe()` (`join_hashtable.cpp:829-848`)를 호출한다
3. `GetRowPointers()` (`join_hashtable.cpp:342-352`)가 hash에서 pointer table을 조회하여 매칭 후보를 찾는다
4. `ScanStructure::Next()`가 join type에 따라 결과를 생성한다

### 3.2 Linear Probing with Salt

`GetRowPointersInternal()` (`join_hashtable.cpp:262-335`)에서 linear probing이 수행된다:

1. Hash 값으로 초기 위치를 계산한다 (`row_ht_offset = row_hash & bitmask`)
2. **Salt 비교**: 해당 위치의 entry가 occupied이면 salt를 비교한다. Salt가 다르면 다음 위치로 이동 (`IncrementAndWrap()`)
3. Salt가 일치하면 실제 key 비교 대상으로 추가한다
4. **Row 비교**: `row_matcher_build.Match()`로 실제 key 값을 비교한다
5. Key가 불일치하면 offset을 증가시켜 다시 probing한다
6. 이 과정을 모든 match가 확인될 때까지 반복한다

### 3.3 Chain Traversal

초기 probe에서 찾은 row의 NEXT POINTER를 따라가며 같은 key를 가진 모든 매칭 row를 탐색한다. `ScanStructure::AdvancePointers()` (`join_hashtable.cpp:1043-1064`)가 체인의 다음 원소로 이동한다. `chains_longer_than_one` 플래그가 false이면 (모든 key가 유일) chain traversal을 건너뛴다.

## 4. Partitioning 전략

DuckDB는 **radix partitioning**을 사용한다. `INITIAL_RADIX_BITS = 4`로 시작하여 16개 파티션으로 데이터를 분배한다 (`join_hashtable.hpp:380`).

### 4.1 RadixPartitionedTupleData

Build 시 데이터는 `RadixPartitionedTupleData` (`sink_collection`)에 저장된다. Hash 값의 상위 비트를 기준으로 파티션을 결정한다. 이 partitioning은 두 가지 목적을 달성한다:

1. **In-memory join**: `Unpartition()` (`join_hashtable.cpp:1678-1680`)으로 모든 파티션을 하나로 합치고 전체 hash table을 구축한다
2. **External join**: 파티션 단위로 hash table을 구축하고 probe하여, 한 번에 하나의 파티션만 메모리에 올린다

### 4.2 Repartitioning

메모리가 부족하면 radix bits를 증가시켜 더 많은 파티션으로 재분배한다. `SetRepartitionRadixBits()` (`join_hashtable.cpp:1682-1699`)에서 새 radix bits를 결정하고, `HashJoinRepartitionEvent` (`physical_hash_join.cpp:764-861`)가 실제 재분배를 수행한다. 각 thread-local HT에 대해 `Repartition()` 태스크를 생성하여 병렬로 진행한다.

## 5. Parallelism (병렬 처리)

DuckDB의 hash join 병렬화는 **Morsel-Driven Parallelism** (Leis et al., SIGMOD 2014) 모델을 따른다. 전체 파이프라인이 morsel(데이터 청크) 단위로 분할되어 여러 스레드가 독립적으로 처리한다.

### 5.1 Build Side 병렬화

**Phase 1: Parallel Sink (데이터 수집)**
- 각 스레드는 자신만의 `HashJoinLocalSinkState`를 가지며, 여기에 독립적인 `JoinHashTable`이 포함된다 (`physical_hash_join.cpp:372-409`)
- `PhysicalHashJoin::Sink()`에서 각 스레드가 자신의 morsel에 대해 독립적으로 key 추출, hash 계산, 데이터 append를 수행한다
- 스레드 간 동기화 없이 진행되므로 lock contention이 없다

**Phase 2: Combine**
- 각 스레드의 local hash table을 global state에 모은다 (`Combine()`, `physical_hash_join.cpp:512-531`)
- `gstate.Lock()`으로 보호하며 `local_hash_tables` 벡터에 push한다

**Phase 3: Parallel Finalize (hash table 구축)**
Finalize는 두 개의 이벤트 체인으로 구성된다:

1. **`HashJoinTableInitEvent`** (`physical_hash_join.cpp:643-677`): Pointer table을 병렬로 초기화한다. 스레드 수의 4배만큼 태스크를 생성하되, 태스크당 최소 `MINIMUM_ENTRIES_PER_TASK = 131072` 엔트리를 할당한다.

2. **`HashJoinFinalizeEvent`** (`physical_hash_join.cpp:703-742`): 데이터 청크를 병렬로 처리하여 hash 삽입을 수행한다. 태스크당 `CHUNKS_PER_TASK = 64` 청크를 할당한다. 병렬 삽입 시 `InsertRowToEntry<PARALLEL=true>()`에서 `compare_exchange_strong/weak`를 사용하여 lock-free로 엔트리를 삽입한다.

**Skew 감지와 단일 스레드 폴백**:
- `KeysAreSkewed()` (`physical_hash_join.cpp:544-549`)가 가장 큰 파티션이 전체의 33% 이상을 차지하는지 확인한다
- 데이터가 skewed이면 병렬 finalize 대신 단일 스레드로 폴백한다. 이는 동일 키에 대한 compare-and-swap 경합을 방지하기 위함이다
- 전체 row가 `PARALLEL_CONSTRUCT_THRESHOLD = 1,048,576` 미만이면 역시 단일 스레드로 처리한다

### 5.2 Probe Side 병렬화

In-memory join에서 probe는 파이프라인의 operator로 동작한다. 각 스레드가 자신의 morsel에 대해 독립적으로 `ExecuteInternal()`을 호출한다. Hash table은 읽기 전용이므로 동기화가 필요 없다 (단, RIGHT/FULL OUTER join의 `found_match` 플래그 설정은 의도적 data race로, true만 기록되므로 안전하다 — `join_hashtable.cpp:1118-1128` 주석 참조).

### 5.3 External Hash Join의 병렬 처리

메모리가 부족한 경우 **external hash join**으로 전환된다 (`physical_hash_join.cpp:1050-1104`). `HashJoinGlobalSourceState`가 여러 단계를 관리한다 (`physical_hash_join.cpp:1270, HashJoinSourceStage`):

1. **BUILD 단계**: 현재 파티션의 데이터로 hash table을 구축한다. 스레드들이 `AssignTask()` (`physical_hash_join.cpp:1514-1551`)를 통해 청크 범위를 할당받아 병렬로 `Finalize()`를 수행한다.
2. **PROBE 단계**: Spill된 probe 데이터를 읽어 hash table을 조회한다. `ColumnDataConsumer`를 통해 스레드별 청크를 할당한다.
3. **SCAN_HT 단계**: FULL/RIGHT OUTER join에서 매칭되지 않은 build 측 row를 스캔한다.

이 세 단계가 파티션 수만큼 반복된다. 스레드 동기화는 `global_stage` atomic 변수와 `TryPrepareNextStage()` (`physical_hash_join.cpp:1409-1439`)로 관리된다. 모든 스레드가 현재 단계를 완료하면 (`build_chunk_done == build_chunk_count` 등) 다음 단계로 전환된다. 작업이 없는 스레드는 `BlockSource()`로 대기하다가 새 단계가 시작되면 `UnblockTasks()`로 깨워진다.

### 5.4 Probe Spill

External join에서 probe 데이터도 파티션별로 spill된다. `ProbeAndSpill()` 함수에서 현재 활성 파티션에 해당하는 probe 데이터만 즉시 처리하고, 나머지는 `ProbeSpill`에 저장한다. ProbeSpill 내부적으로 `PartitionedColumnData`를 사용하여 radix partitioning된 형태로 저장하므로, 다음 라운드에서 해당 파티션의 probe 데이터를 효율적으로 읽을 수 있다.

## 6. Memory Management

### 6.1 TemporaryMemoryState

`TemporaryMemoryManager`를 통해 operator별 메모리 사용량을 관리한다 (`HashJoinGlobalSinkState::temporary_memory_state`, `physical_hash_join.cpp:334`). `PrepareFinalize()` (`physical_hash_join.cpp:602-617`)에서 최소 필요 메모리와 전체 크기를 설정한다.

### 6.2 External Join 전환

`Finalize()`에서 `temporary_memory_state->GetReservation() < total_size`이면 external join으로 전환한다 (`physical_hash_join.cpp:1050`). 전환 시:

1. Load factor를 `2.0`에서 `1.5`로 줄인다 — 이것만으로도 메모리 제한 내에 들어올 수 있다
2. 여전히 초과하면 `SetRepartitionRadixBits()`로 radix bits를 증가시켜 더 작은 파티션으로 분할한다
3. 파티션 단위로 build → probe → scan_ht 순환을 반복한다
4. 완료된 파티션은 `completed_partitions` 마스크에 기록되고 메모리를 해제한다

### 6.3 Bloom Filter

Filter pushdown 최적화로, build 측 데이터로 **Bloom Filter**를 구축하여 probe 측 스캔 시 불필요한 row를 조기에 필터링할 수 있다 (`JoinFilterPushdownInfo::PushBloomFilter()`, `physical_hash_join.cpp:930-942`). 단일 키 equality join에서 probe 측 카디널리티가 build 측보다 클 때 활성화된다.

## 7. Join Types 지원

DuckDB는 `ScanStructure::Next()` (`join_hashtable.cpp:896-931`)에서 join type에 따라 다른 처리 경로를 선택한다:

| Join Type | 구현 함수 | 설명 |
|-----------|-----------|------|
| **INNER** | `NextInnerJoin()` | 매칭된 row 쌍을 모두 출력. Chain traversal로 1:N 매칭 처리 |
| **LEFT (OUTER)** | `NextLeftJoin()` | Inner join 후, 매칭 안 된 LHS row에 대해 RHS를 NULL로 채워 출력 |
| **RIGHT (OUTER)** | `NextInnerJoin()` + `ScanFullOuter()` | Inner와 동일하게 처리 후, `ScanFullOuter()`로 매칭 안 된 RHS row 출력 |
| **FULL OUTER** | `NextLeftJoin()` + `ScanFullOuter()` | LEFT + RIGHT 결합. `found_match` bool 필드로 추적 |
| **SEMI** | `NextSemiJoin()` | `ScanKeyMatches()`로 매칭 여부만 확인, 매칭된 LHS row만 출력 (1회) |
| **ANTI** | `NextAntiJoin()` | Semi의 반대 — 매칭 **안 된** LHS row만 출력 |
| **MARK** | `NextMarkJoin()` | 각 LHS row에 대해 boolean 결과 컬럼 생성. Correlated subquery 지원 포함 |
| **SINGLE** | `NextSingleJoin()` | 스칼라 서브쿼리용. 매칭이 2개 이상이면 에러 발생 |
| **RIGHT SEMI/ANTI** | `NextRightSemiOrAntiJoin()` | RHS 기준 semi/anti. `found_match` 필드를 체인 전체에 설정 |

SEMI/ANTI join에서는 `insert_duplicate_keys = false`로 설정하여 build 시 중복 key 삽입을 방지한다 (`join_hashtable.cpp:124-127`). 이로써 hash table 크기를 줄이고 probe 성능을 향상시킨다.

FULL/RIGHT OUTER join에서는 row 레이아웃에 boolean 필드 (`found_match`)를 추가하여 (`join_hashtable.cpp:82-86`) probe 시 매칭 여부를 기록한다. `ScanFullOuter()` (`join_hashtable.cpp:1522-1584`)에서 이 필드가 false인 row를 스캔하여 LHS를 NULL로 채운 결과를 출력한다.

## 8. Key References

### 소스 코드 경로

| 파일 | 주요 함수/클래스 |
|------|------------------|
| `src/execution/operator/join/physical_hash_join.cpp` | `PhysicalHashJoin::Sink()`, `Combine()`, `Finalize()`, `ExecuteInternal()`, `HashJoinFinalizeEvent`, `HashJoinRepartitionEvent` |
| `src/execution/join_hashtable.cpp` | `JoinHashTable::Build()`, `Probe()`, `Finalize()`, `InsertHashesLoop()`, `GetRowPointersInternal()`, `ScanStructure::Next()` |
| `src/include/duckdb/execution/join_hashtable.hpp` | `JoinHashTable` 클래스, `ScanStructure`, `ProbeSpill`, `ProbeState`, `InsertState` |
| `src/include/duckdb/execution/ht_entry.hpp` | `ht_entry_t` 구조체, `ExtractSalt()`, `IncrementAndWrap()` |
| `src/execution/operator/join/perfect_hash_join_executor.cpp` | `PerfectHashJoinExecutor::CanDoPerfectHashJoin()`, `BuildPerfectHashTable()`, `ProbePerfectHashTable()` |
| `src/execution/radix_partitioned_hashtable.cpp` | `RadixPartitionedHashTable`, `RadixHTConfig` |

### 논문 및 참고 문헌

1. **"Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age"** — Viktor Leis, Peter Boncz, Alfons Kemper, Thomas Neumann, SIGMOD 2014. DuckDB의 morsel 단위 병렬 실행 모델의 이론적 기반.

2. **"Saving Private Hash Join: How to Implement an External Hash Join within Limited Memory"** — Kuiper et al., VLDB 2024. DuckDB의 external hash join 구현에 직접적으로 적용된 논문. 파티션 단위 build-probe 순환과 dynamic repartitioning 전략.
