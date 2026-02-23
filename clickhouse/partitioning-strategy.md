# ClickHouse Hash Join Partitioning 전략

## 요약

ClickHouse는 두 가지 hash join partitioning을 제공한다:

1. **ConcurrentHashJoin** — in-memory 병렬 build를 위해 `TwoLevelHashMap`의 bucket을 thread(slot) 간에 분할하고, build 완료 후 O(1) merge로 통합 hash map을 구성한다.
2. **GraceHashJoin** — 메모리 초과 시 데이터를 hash 기반으로 disk bucket에 spill하고, 완료되지 않은 bucket을 순차적으로 in-memory join으로 처리한다.

두 전략 모두 **cache-conscious radix partitioning이 아니다.** ConcurrentHashJoin은 lock-free 병렬 build를, GraceHashJoin은 메모리 초과 대응을 목적으로 한다.

---

## 1. 용어 정의

### ConcurrentHashJoin 관련

| 용어 | 실체 | 개수 | 설명 |
|------|------|------|------|
| **Slot** | 독립된 `HashJoin` 인스턴스 | thread 수 (max 256, power-of-2) | build phase에서 lock 없이 병렬 insert하기 위한 단위. 각 slot은 자신의 `TwoLevelHashMap`을 보유한다. |
| **Bucket** | `TwoLevelHashMap` 내부의 sub-table (`impls[j]`) | 256개 (고정, `BITS_FOR_BUCKET=8`) | hash 상위 8bit으로 결정되는 hash table 내부 분할 단위. 각 bucket은 독립된 메모리 영역이므로 O(1) move가 가능하다. |
| **impl** | 각 bucket 내부의 open-addressing hash table | bucket당 1개 | key→value를 실제 저장하는 최종 자료구조. `TwoLevelHashMap::impls[j]`로 접근한다. |
| **ScatteredBlock** | block + row index 목록 | slot당 1개 | 원본 block을 물리적으로 복사하지 않고, 각 slot에 속하는 row의 인덱스만 보관하는 zero-copy 구조. |

### GraceHashJoin 관련

| 용어 | 실체 | 개수 | 설명 |
|------|------|------|------|
| **FileBucket** | disk 기반 left/right 블록 저장소 | 동적 (초기 설정값 → 2배씩 증가, max 설정) | 각 bucket의 left/right 데이터를 임시 파일에 저장. `tryAddLeftBlock()`/`tryAddRightBlock()`으로 non-blocking write. |
| **Current bucket** | 현재 in-memory로 처리 중인 bucket | 1개 | 이 bucket의 데이터만 in-memory `HashJoin`에 적재하여 즉시 join. 나머지 bucket은 disk에 spill. |

---

## 2. ConcurrentHashJoin: 병렬 Build 구조

### 2.1 핵심 아이디어

**"각 slot이 독립된 TwoLevelHashMap을 갖되, 256개 bucket 중 자기 소유분에만 write → build 완료 후 bucket을 move하여 하나의 완전한 hash table로 조립"**

이 설계로 build는 lock-free 병렬로, probe는 단일 hash table에서 수행할 수 있다.

### 2.2 구조 예시 (slots=2, buckets=8로 단순화)

실제로는 256 bucket이지만 이해를 위해 8 bucket으로 축소한다.

**Step 1 — Slot 생성**: 각 slot은 자신의 `TwoLevelHashMap`을 보유한다.

```
hash_joins[0].map:  [B0] [B1] [B2] [B3] [B4] [B5] [B6] [B7]   ← 모두 비어있음
hash_joins[1].map:  [B0] [B1] [B2] [B3] [B4] [B5] [B6] [B7]   ← 모두 비어있음
```

**Step 2 — Bucket 소유권 분배** (stride 패턴, `bucket_index % slots`):

```
Slot 0 소유: bucket 0, 2, 4, 6
Slot 1 소유: bucket 1, 3, 5, 7
```

**Step 3 — Row dispatch**: 각 row의 hash → bucket 번호 → `bucket % slots`로 slot 결정.

```
Row "Alice"  → bucket 5 → slot 5%2 = 1 → hash_joins[1]
Row "Bob"    → bucket 2 → slot 2%2 = 0 → hash_joins[0]
Row "Carol"  → bucket 3 → slot 3%2 = 1 → hash_joins[1]
Row "Dave"   → bucket 4 → slot 4%2 = 0 → hash_joins[0]
```

**Step 4 — 병렬 Build**: 각 slot의 HashJoin에 독립적으로 insert. 완전히 독립된 메모리 영역이므로 lock 불필요.

```
hash_joins[0].map:  [B0:     ] [       ] [B2: Bob ] [       ] [B4: Dave] [       ] [B6:     ] [       ]
                     ↑ slot 0              ↑ slot 0             ↑ slot 0             ↑ slot 0

hash_joins[1].map:  [       ] [B1:     ] [       ] [B3:Carol] [       ] [B5:Alice] [       ] [B7:     ]
                               ↑ slot 1             ↑ slot 1             ↑ slot 1             ↑ slot 1
```

소유하지 않은 bucket은 항상 비어 있다. dispatch가 `bucket % slots` 기준이므로 보장된다.

**Step 5 — Merge (onBuildPhaseFinish)**: slot 1~N의 bucket들을 slot 0으로 `std::move`. 데이터 복사 없이 pointer swap만 수행한다.

```
hash_joins[0].map (merge 후 — 완전한 hash table):
  [B0:     ] [B1:     ] [B2: Bob ] [B3:Carol] [B4: Dave] [B5:Alice] [B6:     ] [B7:     ]
   ↑ 원래 0   ↑ 1에서     ↑ 원래 0   ↑ 1에서     ↑ 원래 0   ↑ 1에서     ↑ 원래 0   ↑ 1에서
              move                  move                  move                  move
```

**Step 6 — Probe**: 통합된 `hash_joins[0]`의 map 하나로 probe. 읽기 전용이므로 여러 thread가 동시에 접근 가능. **dispatch 불필요.**

### 2.3 코드 근거

**Slot 수 결정** — thread 수 기반, cache 크기 무관 (`ConcurrentHashJoin.cpp:155`):
```cpp
, slots(toPowerOfTwo(std::min<UInt32>(static_cast<UInt32>(slots_), 256)))
```

**Bucket 결정** — hash 상위 8bit 추출 (`TwoLevelHashTable.h:54`):
```cpp
static size_t getBucketFromHash(size_t hash_value) {
    return (hash_value >> (32 - BITS_FOR_BUCKET)) & MAX_BUCKET;  // 상위 8bit → 0~255
}
```

**Row → Slot 매핑** (`ConcurrentHashJoin.cpp:488-502`):
```cpp
template <typename HashTable>
static IColumn::Selector hashToSelector(const HashTable & hash_table,
                                         const BlockHashes & hashes, size_t num_shards)
{
    for (size_t i = 0; i < num_rows; ++i)
        selector[i] = hash_table.getBucketFromHash(hashes[i]) & (num_shards - 1);
    return selector;
}
```

**Stride 기반 소유권** — reserve 시 (`ConcurrentHashJoin.cpp:121`):
```cpp
for (size_t j = idx; j < map.NUM_BUCKETS; j += slots)
    map.impls[j].reserve(reserve_size / map.NUM_BUCKETS);
```

**O(1) Merge** — bucket pointer move (`ConcurrentHashJoin.cpp:680-685`):
```cpp
for (size_t j = idx; j < lhs_map.NUM_BUCKETS; j += slots)
{
    if (!lhs_map.impls[j].empty())
        throw Exception(...);  // slot 0에는 이 bucket이 비어있어야 함
    lhs_map.impls[j] = std::move(rhs_map.impls[j]);
}
```

**Probe 시 dispatch 생략** (`ConcurrentHashJoin.cpp:378-381`):
```cpp
if (hash_joins[0]->data->twoLevelMapIsUsed())
    dispatched_blocks.emplace_back(std::move(block));  // scatter 안 함
else
    dispatched_blocks = dispatchBlock(...);
```

### 2.4 Radix Partitioning과의 차이

| 특성 | Radix Partitioning (학술) | ClickHouse ConcurrentHashJoin |
|------|--------------------------|-------------------------------|
| **파티션 수 결정** | LLC / TLB 크기 기반 | thread 수 기반 (max 256) |
| **Multi-pass** | 2+ pass (cache-conscious) | 단일 pass |
| **목적** | 각 partition이 LLC에 fit | lock-free 병렬 build |
| **Probe에서** | partition별 독립 probe | 통합 hash map으로 공유 probe |
| **Cache 최적화** | 명시적 (partition ⊆ LLC) | 없음 |

ConcurrentHashJoin의 `TwoLevelHashMap` 자체가 256 bucket으로 나뉘어 있어 resize 시 부수적 cache 이점이 있지만 (`TwoLevelHashTable.h:15` 주석: "in theory, resizes are cache-local in a larger range of sizes"), 이는 join partitioning이 아니라 hash table 구현의 부수적 효과다.

---

## 3. GraceHashJoin: Disk Spill 기반 Partitioning

### 3.1 3단계 처리 모델

**Stage 1 — Build**: right 블록을 `WeakHash32` + `intHashCRC32`로 scatter → bucket 0은 in-memory `HashJoin`에 적재, 나머지는 `FileBucket`에 disk spill. 메모리 초과 시 `rehashBuckets()`로 bucket 수를 2배 증가.

**Stage 2 — Probe**: left 블록을 동일하게 scatter → 현재 활성 bucket만 즉시 probe, 나머지는 disk spill.

**Stage 3 — Delayed Processing**: `getDelayedBlocks()`에서 미처리 bucket을 순차적으로 disk에서 읽어 in-memory join으로 처리.

### 3.2 동적 Rehash

```cpp
// GraceHashJoin.cpp:368
const size_t to_size = buckets.size() * 2;
```

Rehash 시 기존 in-memory 데이터를 `releaseJoinedBlocks()`로 추출하여 새 bucket 수 기준으로 re-scatter한다. 이미 disk에 기록된 데이터는 재배치하지 않고, Stage 3에서 lazy하게 재분배한다.

### 3.3 Non-blocking Flush

`flushBlocksToBuckets()`는 `std::try_to_lock` + 랜덤 순서 순회로 lock contention을 최소화한다 (`GraceHashJoin.cpp:227-249`).

---

## 4. Key References

### 소스 코드 경로

| 파일 | 주요 내용 |
|------|----------|
| `src/Interpreters/ConcurrentHashJoin.cpp` | 병렬 build, dispatch, merge, probe |
| `src/Interpreters/GraceHashJoin.cpp` | Grace hash join, FileBucket, rehash, delayed processing |
| `src/Common/HashTable/TwoLevelHashTable.h` | 256 bucket two-level hash table, `getBucketFromHash()` |
| `src/Interpreters/HashJoin/ScatteredBlock.h` | Zero-copy block dispatch |
| `src/Interpreters/JoinUtils.cpp` | `scatterBlockByHash()` — GraceHashJoin용 hash scatter |
