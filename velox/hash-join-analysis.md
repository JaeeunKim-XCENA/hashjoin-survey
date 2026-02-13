# Velox Hash Join 구현 분석

## 1. Hash Table 구조

Velox의 hash join은 F14 해시 테이블에서 영감을 받은 **tag 기반 open addressing** 방식을 사용한다. 핵심 구현은 `HashTable<ignoreNullKeys>` 클래스(`velox/exec/HashTable.h`)에 있으며, 세 가지 hash mode를 지원한다:

```cpp
enum class HashMode { kHash, kArray, kNormalizedKey };
```

### Bucket 구조 (F14-inspired 16-way probing)

Hash table의 기본 단위는 `Bucket` 클래스로, **128바이트(2 cache line)** 크기이다 (`HashTable.h:831` — `static_assert(sizeof(Bucket) == 128)`). 각 bucket은 16개의 slot으로 구성되며:

- **TagVector (16 bytes)**: 16개 slot의 tag를 담는 SIMD 벡터. SSE2에서는 `__m128i`, NEON에서는 `uint8x16_t` 사용.
- **Pointers (96 bytes)**: 16개의 6-byte(48-bit) 포인터. 가상 주소의 하위 48비트만 저장하여 공간 절약.
- **Padding (16 bytes)**: cache line alignment를 위한 패딩.

**Tag 생성**: hash 값의 상위 비트(bit 38~44)에서 7비트를 추출하고 최상위 비트를 1로 설정한다 (`HashTable.h:453-459`):

```cpp
static uint8_t hashTag(uint64_t hash) {
    return static_cast<uint8_t>(hash >> 38) | 0x80;
}
```

Tag 0x00은 빈 슬롯, 0x7f는 tombstone을 나타낸다 (`ProbeState::kEmptyTag`, `ProbeState::kTombstoneTag` — `HashTable.cpp:100-101`).

### Hash Mode 선택

`decideHashMode()` 함수(`HashTable.cpp:1712-1799`)가 데이터 특성에 따라 최적의 모드를 결정한다:

- **kArray**: key의 value range가 `kArrayHashMaxSize`(2M, 약 16MB) 이하일 때 direct-mapped array 사용. O(1) lookup.
- **kNormalizedKey**: 모든 key를 하나의 64비트 값으로 인코딩 가능할 때 사용. Key 비교를 단일 정수 비교로 최적화.
- **kHash**: 위 두 모드가 불가능할 때 일반적인 hash 기반 probing 사용.

**Load factor**: 0.7 (`kHashTableLoadFactor` — `HashTable.h:132`)로, 이를 초과하면 `checkSize()`에서 rehash를 트리거한다.

## 2. Build Phase

Build phase는 `HashBuild` 연산자(`velox/exec/HashBuild.cpp`)가 담당한다. Build pipeline의 각 Driver가 독립적인 `HashBuild` 인스턴스를 갖는다.

### 데이터 적재 과정

1. **`addInput()`** (`HashBuild.cpp:410-550`): 입력 벡터를 받아 RowContainer에 행 단위로 저장한다.
   - key 컬럼을 `VectorHasher`로 decode
   - null key 처리 (join type에 따라 null row 제거 또는 유지)
   - dependent(non-key) 컬럼을 `DecodedVector`로 decode
   - `RowContainer::newRow()`로 새 행 할당 후 key와 dependent 컬럼을 순서대로 store

2. **Key 분석 (analyzeKeys)**: `addInput()` 과정에서 `VectorHasher::computeValueIds()`를 호출하여 key의 value 분포를 지속적으로 추적한다. kArray나 kNormalizedKey 모드가 불가능해지면 `analyzeKeys_`를 false로 전환한다 (`HashBuild.cpp:514-520`).

3. **Drop Duplicates 최적화**: left semi/anti join에서 `dropDuplicates_`가 true이면, `addInput()` 단계에서 `groupProbe()`를 통해 중복 key를 제거하며 hash table을 점진적으로 빌드한다. 중복 비율이 낮으면 (`abandonHashBuildDedupEarly()` — `HashBuild.cpp:1439-1443`) 이 최적화를 포기하고 일반 모드로 전환한다.

### 테이블 생성

`setupTable()` (`HashBuild.cpp:218-281`)에서 join type에 따라 적절한 `HashTable`을 생성한다:
- Right/Full/Right Semi Project Join → `HashTable<false>` (null key 무시 안 함) + `hasProbedFlag=true`
- 기타 → `HashTable<true>` (null key 무시) 또는 `HashTable<false>` (null-aware 필터 있을 때)

### Row Container

`RowContainer`(`velox/exec/RowContainer.h`)는 행 데이터를 저장하는 컨테이너다. 각 행은 고정 크기 영역에 key와 dependent 컬럼을 연속 저장하며, 가변 길이 데이터는 `HashStringAllocator`를 통해 별도 관리된다. Join build에서 `allowDuplicates`가 true이면 `nextOffset`을 통해 같은 key의 행들을 linked list로 연결한다.

## 3. Probe Phase

Probe phase는 `HashProbe` 연산자(`velox/exec/HashProbe.cpp`)가 담당한다.

### Probe 과정

1. **`asyncWaitForHashTable()`** (`HashProbe.cpp:420-490`): HashJoinBridge로부터 빌드된 hash table을 비동기적으로 받아온다. Dynamic filter pushdown도 이 시점에 수행된다.

2. **`addInput()`**: probe 입력이 들어오면 `decodeAndDetectNonNullKeys()`로 key를 decode하고 null 행을 필터링한다.

3. **`getOutput()` → `getOutputInternal()`** (`HashProbe.cpp:1039-1045`):
   - `prepareForJoinProbe()`로 hash/value ID 계산
   - `joinProbe()`로 첫 번째 매칭 행을 찾음
   - `listJoinResults()`로 결과를 배치 단위로 iterate

### SIMD 기반 Probe

`ProbeState` 클래스(`HashTable.cpp:87-307`)가 probing 로직을 담당한다:

1. **`preProbe()`**: hash 값에서 bucket offset을 계산하고, tag의 16-way broadcast SIMD 벡터를 준비하며, 해당 bucket을 prefetch한다.
2. **`firstProbe()`**: `loadTags()`로 bucket의 16개 tag를 SIMD 로드하고, broadcast된 검색 tag와 **단일 SIMD 비교 명령**으로 16개 슬롯을 동시에 비교한다 (`simd::toBitMask(tagsInTable_ == wantedTags_)`).
3. **`fullProbe()`**: hit bitmask를 순회하며 실제 key 비교를 수행. 빈 슬롯(tag=0)을 만나면 miss로 판정.

**4-way interleaved probing**: `joinProbe()`(`HashTable.cpp:609-651`)에서 4개의 `ProbeState`를 동시에 운용하여 memory latency를 숨긴다:

```cpp
for (; probeIndex + 4 <= numProbes; probeIndex += 4) {
    state1.preProbe(...); state2.preProbe(...);
    state3.preProbe(...); state4.preProbe(...);
    state1.firstProbe(...); state2.firstProbe(...);
    state3.firstProbe(...); state4.firstProbe(...);
    fullProbe<true>(lookup, state1, false);
    fullProbe<true>(lookup, state2, false);
    fullProbe<true>(lookup, state3, false);
    fullProbe<true>(lookup, state4, false);
}
```

**Normalized Key probe 최적화**: `joinNormalizedKeyProbe()`(`HashTable.cpp:696-724`)에서는 64개 row를 배치로 처리하며(`kPrefetchSize=64`), key 비교를 단일 64비트 정수 비교로 수행한다 (`RowContainer::normalizedKey(group_) == keys[row_]`).

**Array mode probe**: `arrayJoinProbe()`(`HashTable.cpp:654-693`)에서는 SIMD gather 명령으로 연속된 row의 포인터를 한 번에 로드한다.

## 4. Partitioning 전략

Velox는 **spill 기반 partitioning**을 사용한다. 메모리 부족 시 hash bit range 기반으로 partition을 나누어 disk에 spill한다.

### Spill Partitioning

`HashBuildSpiller`(`HashBuild.h:405-446`)와 `HashBitRange`를 사용하여 hash 값의 특정 bit range로 partition을 결정한다. `computeSpillPartitions()`(`HashBuild.cpp:712-730`)에서 각 행의 hash 값에서 partition 번호를 추출한다.

### Recursive Spilling

Spill된 partition을 복원할 때 여전히 메모리에 맞지 않으면 **recursive spilling**이 적용된다. `setupSpiller()`(`HashBuild.cpp:283-344`)에서 `startPartitionBit`을 이전 spill의 bit offset + `numPartitionBits`로 설정하여 다른 bit range를 사용한다. `config->exceedSpillLevelLimit()`으로 최대 spill depth를 체크한다.

## 5. Parallelism (병렬 처리) ★

Velox의 hash join 병렬 처리는 **build pipeline 병렬화**, **parallel table construction**, **probe pipeline 병렬화**의 세 단계로 구성된다.

### 5.1 Build Pipeline 병렬화

Build pipeline에는 여러 Driver가 존재하며, 각 Driver가 독립적인 `HashBuild` 인스턴스를 운영한다. 각 인스턴스는 **자체 `HashTable`과 `RowContainer`에 독립적으로 데이터를 축적**한다. 이 단계에서는 동기화가 필요 없다.

### 5.2 Build Barrier와 HashJoinBridge

모든 build Driver가 입력 처리를 완료하면 **barrier synchronization**이 발생한다. `finishHashBuild()`(`HashBuild.cpp:768-932`):

```cpp
if (!operatorCtx_->task()->allPeersFinished(
        planNodeId(), operatorCtx_->driver(), &future_, promises, peers)) {
    setState(State::kWaitForBuild);
    return false;
}
```

- **마지막 Driver가 아닌 경우**: `State::kWaitForBuild` 상태로 전환되고 `future_`에 블록된다.
- **마지막 Driver**: 모든 peer의 hash table을 수집하여 merge 작업을 수행한다.

마지막 Driver는:
1. 모든 peer의 `table_`(RowContainer + VectorHasher 포함)을 `otherTables`로 수집
2. Spiller가 있으면 finalize
3. `prepareJoinTable()`을 호출하여 단일 hash table로 merge
4. `HashJoinBridge::setHashTable()`로 probe side에 전달
5. 모든 peer의 promise를 fulfill하여 깨움

### 5.3 Parallel Join Table Build

`prepareJoinTable()`(`HashTable.cpp:1950-2030`)에서 `otherTables_`를 merge한 후 `rehash()`가 호출되면, **parallel build 조건을 만족하면** `parallelJoinBuild()`(`HashTable.cpp:995-1187`)가 실행된다.

**Parallel build 조건** (`canApplyParallelJoinBuild()` — `HashTable.cpp:980-992`):
1. `isJoinBuild_`가 true
2. `buildExecutor_`가 non-null
3. `otherTables_`가 비어있지 않음 (여러 build thread가 존재)
4. `hashMode_`가 kArray가 아님
5. partition당 entry 수가 `minTableSizeForParallelJoinBuild_` 이상

**Parallel build 과정**:

**Step 1 — Row Partitioning**: 각 sub-table의 행들에 대해 hash 값을 기반으로 **어떤 thread의 partition에 속하는지** 결정한다. `partitionRows()`(`HashTable.cpp:1212-1236`)에서 `buildPartitionBounds_`를 기준으로 bucket offset 범위에 따라 partition 번호를 할당한다.

```cpp
buildPartitionBounds_[i] =
    bits::roundUp(((sizeMask_ + 1) / numPartitions) * i, kBucketSize);
```

각 partition의 경계는 **cache line 단위**로 정렬되어 false sharing을 방지한다.

**Step 2 — Parallel Insert**: 각 thread가 자신의 partition에 해당하는 행만 hash table에 삽입한다. `buildJoinPartition()`(`HashTable.cpp:1239-1261`)에서 `TableInsertPartitionInfo`를 사용하여 자신의 bucket 범위 내에서만 삽입을 수행한다. 범위를 벗어나는 행은 `overflow` 벡터에 추가된다.

**Step 3 — Overflow 처리**: 모든 parallel build가 완료된 후, 메인 thread가 순차적으로 overflow 행들을 삽입한다 (`parallelJoinBuild()` 끝부분, `HashTable.cpp:1175-1187`).

**Tag 로드 시 TSAN 비활성화**: parallel build 중 서로 다른 thread가 인접 bucket의 tag를 SIMD로 로드할 때 data race가 보고될 수 있으므로, `loadTags()`에 `__no_sanitize__("thread")` 어트리뷰트가 적용되어 있다 (`HashTable.h:468-481`).

**AsyncSource 활용**: 각 step은 `folly::Executor`와 `AsyncSource<bool>`을 통해 실행된다. 마지막 partition은 현재 thread에서 실행하여 thread 유휴 시간을 줄인다 (`parallelJoinBuild()`, `HashTable.cpp:1097-1098` — `last` 플래그).

### 5.4 Probe Pipeline 병렬화

Probe 측도 여러 Driver가 **동일한 shared hash table** (`std::shared_ptr<BaseHashTable>`)을 참조하여 독립적으로 probe한다. Hash table은 read-only이므로 동기화가 필요 없다.

**Build-side output 병렬화**: Right/Full join에서 build-side의 unmatched row를 출력할 때, `canOutputBuildRowsInParallel_` 플래그(`HashProbe.h:387`)가 true이면 각 probe Driver가 `HashJoinBridge::getAndIncrementUnclaimedRowContainerId()`를 통해 서로 다른 RowContainer를 claim하여 병렬로 처리한다 (`HashJoinBridge.h:149-151`).

**Last Prober 동기화**: probe가 완료되면 마지막 probe operator가 `probeFinished()`를 호출하여 build 측에 다음 spill partition 복원을 알린다.

### 5.5 Bloom Filter Parallel Build

Bloom filter도 parallel build와 동일한 방식으로 병렬 구축된다:
1. 각 sub-table의 행을 Bloom filter block 기준으로 partition
2. 각 partition별로 병렬로 Bloom filter에 값을 insert
이 과정은 `parallelJoinBuild()` 내의 `bloomFilterPartitionSteps`와 `bloomFilterBuildSteps`에서 수행된다 (`HashTable.cpp:1117-1173`).

## 6. Memory Management

### Spill-to-Disk

Velox는 **memory arbitration** 기반의 spill 메커니즘을 사용한다.

- **`ensureInputFits()`** (`HashBuild.cpp:552-635`): 입력 처리 전에 필요한 메모리를 예측하고 reservation을 시도한다. 실패 시 `Operator::ReclaimableSectionGuard`를 통해 memory arbitrator가 이 operator를 spill 대상으로 선택할 수 있도록 한다.
- **`ensureTableFits()`** (`HashBuild.cpp:934-975`): table build 전에 hash table 크기를 예측하여 메모리를 확보한다.
- **`reclaim()`** (`HashBuild.cpp:1257-1333`): memory arbitration에 의해 호출되며, 모든 peer build operator의 spiller를 사용하여 RowContainer 데이터를 disk에 spill한다. `spillHashJoinTable()` 유틸리티 함수를 사용한다.

### Spill 복원 사이클

1. Build 측 spill → probe 측 대응 partition도 spill
2. Probe 완료 후 `probeFinished()` → `HashJoinBridge`가 다음 spill partition 선택
3. Build 측이 spill partition을 shard로 나누어 병렬 복원
4. 복원된 데이터로 새 hash table build → 대응 probe partition 복원 → probe 재개
5. 필요 시 recursive spilling 수행

### Hash Table Caching

`HashTableCache`(`velox/exec/HashTableCache.h`)를 통해 동일 query 내 다른 task에서 빌드된 hash table을 재사용할 수 있다. `setupCachedHashTable()`와 `getHashTableFromCache()`(`HashBuild.cpp:138-192`)에서 cache hit/miss를 처리한다.

## 7. Join Types 지원

Velox는 다양한 join type을 지원하며, 각 type에 따라 hash table 생성과 probe 동작이 달라진다.

| Join Type | `ignoreNullKeys` | `allowDuplicates` | `hasProbedFlag` | 특이 사항 |
|---|---|---|---|---|
| Inner | true | true | false | 기본 동작 |
| Left (Outer) | true | true | false | `includeMisses=true`로 miss 행 포함 |
| Right (Outer) | **false** | true | **true** | `listNotProbedRows()`로 unmatched build 행 출력 |
| Full Outer | **false** | true | **true** | Left + Right의 조합 |
| Left Semi Filter | true | **false** (dedup) | false | Build 시 중복 제거 (`dropDuplicates_`) |
| Left Semi Project | true | true | false | `fillLeftSemiProjectMatchColumn()`으로 match 여부를 bool 컬럼으로 출력 |
| Right Semi Filter | true | true | **true** | `listProbedRows()`로 probed build 행 출력 |
| Right Semi Project | **false** | true | false | `listAllRows()`로 모든 build 행 + match 여부 출력 |
| Anti | true | true | false | match 없는 probe 행만 출력 |
| Null-Aware Anti | true→false* | true | false | build에 null key 있으면 결과 없음 (필터 없을 때) |

*Null-Aware join with filter는 `HashTable<false>`를 사용하여 null key도 hash table에 저장한다.

### Join Filter 처리

`HashProbe::filter_`(`HashProbe.h:460`)로 post-join 필터를 적용한다. Null-aware anti join의 경우 `applyFilterOnTableRowsForNullAwareJoin()`에서 null key row에 대해 별도 필터 평가를 수행한다.

### Probed Flag

Right/Full join에서 build 행의 probe 여부를 추적하기 위해 `RowContainer`에 per-row probed flag를 저장한다. Spill 시에도 이 flag가 보존된다 (`spillProbedFlagChannel_` — `HashBuild.h:358`).

## 8. Key References

### 소스 코드 파일 및 주요 함수

| 파일 | 주요 함수/클래스 | 역할 |
|---|---|---|
| `velox/exec/HashTable.h` | `HashTable<ignoreNullKeys>`, `Bucket`, `BaseHashTable` | Hash table 핵심 자료 구조 |
| `velox/exec/HashTable.cpp` | `parallelJoinBuild()`, `prepareJoinTable()`, `joinProbe()`, `partitionRows()`, `buildJoinPartition()`, `insertForJoinWithPrefetch()` | Hash table 구현 |
| `velox/exec/HashBuild.h/cpp` | `HashBuild::addInput()`, `finishHashBuild()`, `setupTable()`, `ensureInputFits()`, `reclaim()` | Build operator |
| `velox/exec/HashProbe.h/cpp` | `HashProbe::getOutputInternal()`, `asyncWaitForHashTable()`, `pushdownDynamicFilters()` | Probe operator |
| `velox/exec/HashJoinBridge.h/cpp` | `HashJoinBridge::setHashTable()`, `tableOrFuture()`, `probeFinished()` | Build-Probe 동기화 |
| `velox/exec/Spiller.h/cpp` | `HashBuildSpiller`, `SpillerBase` | Spill 지원 |
| `velox/exec/VectorHasher.h/cpp` | `VectorHasher::computeValueIds()`, `enableValueRange()` | Key encoding 및 hash 계산 |
| `velox/exec/RowContainer.h` | `RowContainer::newRow()`, `store()`, `listPartitionRows()` | 행 데이터 저장 |

### 논문 및 참고 자료

- **Pedro Pedreira et al., "Velox: Meta's Unified Execution Engine"**, VLDB 2022. Velox의 전체 아키텍처와 hash join의 병렬 처리 설계를 기술.
- **Facebook F14 Hash Table**: Velox의 tag 기반 16-way bucket 구조는 F14의 `F14ValueMap`에서 영감을 받았다. SIMD를 활용한 tag 비교와 6-byte 포인터 압축이 핵심.
- **Velox GitHub Repository**: https://github.com/facebookincubator/velox — 본 분석의 모든 코드 참조 출처.
