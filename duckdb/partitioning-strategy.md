# DuckDB Radix Partitioning 심층 분석

## 요약

DuckDB의 radix partitioning은 **메모리 관리를 위한 grace hash join**의 핵심 메커니즘이다. Classic radix join (Boncz et al., ICDE 1999)이 **TLB/cache 최적화**를 목적으로 multi-pass partitioning을 수행하는 것과 달리, DuckDB는 **계층적 repartitioning이 가능한 파티셔닝 scheme**으로서 radix 방식을 채택했다.

핵심 특성:
- **Streaming 파티셔닝**: histogram 없이 데이터가 도착하는 즉시 파티션에 append (chunked storage 기반)
- **동적 repartitioning**: 초기 16개 파티션(INITIAL_RADIX_BITS=4)에서 시작하여, 메모리 부족 시 radix bits를 증가시켜 세분화 (hash 재계산 불필요)
- **Probe-side spill**: 별도 파티셔닝 패스 없이, probe와 동시에 `RadixPartitioning::Select`로 active/spill 분리

---

## 1. Radix Partitioning 개요

DuckDB는 hash 값의 **상위 비트**를 기준으로 파티션을 결정한다. 초기 설정은 `INITIAL_RADIX_BITS = 4`로 16개 파티션이다 (`join_hashtable.hpp:380`).

```cpp
// radix_partitioning.cpp:10-25 — RadixPartitioningConstants
template <idx_t radix_bits>
struct RadixPartitioningConstants {
    static constexpr idx_t NUM_PARTITIONS = RadixPartitioning::NumberOfPartitions(radix_bits);
    static constexpr idx_t SHIFT = RadixPartitioning::Shift(radix_bits);
    static constexpr hash_t MASK = RadixPartitioning::Mask(radix_bits);

    static hash_t ApplyMask(const hash_t hash) {
        return (hash & MASK) >> SHIFT;  // 상위 비트 추출 → 파티션 인덱스
    }
};
```

파티션 인덱스 계산은 단순한 bitmask + shift 연산으로, `radix_bits=4`일 때 hash의 상위 4비트가 0~15 범위의 파티션 인덱스가 된다. `RadixBitsSwitch()`가 컴파일 타임에 radix bits별로 특수화된 템플릿 함수를 선택하여 호출한다 (0~12비트까지 지원, `MAX_RADIX_BITS=12`).

파티셔닝은 두 가지 시나리오에서 다른 역할을 한다:

| 시나리오 | 동작 |
|----------|------|
| **In-memory join** | `Unpartition()`으로 16개 파티션을 하나로 합쳐서 단일 hash table 구축 — 파티셔닝이 사실상 의미 없음 |
| **External join** | 파티션 단위로 hash table을 구축하고 probe — 한 번에 하나의 파티션만 메모리에 올림 |

---

## 2. Build-Side Streaming Partitioning

### 2.1 RadixPartitionedTupleData

Build 시 데이터는 `RadixPartitionedTupleData` (`sink_collection`)에 저장된다:

```cpp
// join_hashtable.cpp:114-115 — 생성자에서 즉시 파티션 구조 초기화
sink_collection = make_uniq<RadixPartitionedTupleData>(
    buffer_manager, layout_ptr, MemoryTag::HASH_TABLE,
    radix_bits,                    // INITIAL_RADIX_BITS = 4 → 16 파티션
    layout_ptr->ColumnCount() - 1  // hash column index
);
```

### 2.2 AppendUnified — Streaming 파티셔닝

각 chunk가 Sink될 때 `JoinHashTable::Build()`에서 즉시 파티셔닝된다:

```cpp
// join_hashtable.cpp:448-455 — Build() 함수, chunk 단위로 호출됨
Hash(keys, *current_sel, added_count, hash_values);  // hash 계산
sink_collection->AppendUnified(...);                   // 즉시 파티셔닝
```

`AppendUnified` 내부 동작 (`partitioned_tuple_data.cpp:54-88`):

1. **`ComputePartitionIndices()`** — 각 row의 hash 상위 비트로 파티션 인덱스 계산
2. **`BuildPartitionSel()`** — 파티션별 selection vector 구성
3. 각 파티션의 `TupleDataCollection`에 해당 row들을 append

```cpp
// radix_partitioning.cpp:84-91 — ComputePartitionIndicesFunctor
template <idx_t radix_bits>
static void Operation(Vector &hashes, Vector &partition_indices, ...) {
    using CONSTANTS = RadixPartitioningConstants<radix_bits>;
    UnaryExecutor::Execute<hash_t, hash_t>(hashes, partition_indices, append_count,
        [&](hash_t hash) { return CONSTANTS::ApplyMask(hash); });
}
```

### 2.3 Histogram이 필요 없는 이유

학술적 2-pass radix partition은 연속 메모리 배열(contiguous array)에 데이터를 배치하기 위해 histogram + prefix sum이 필수적이다. DuckDB는 이와 다르게 **파티션별 chunked storage** (`TupleDataCollection`)를 사용하므로, 미리 전체 크기를 알 필요가 없다.

| | 2-pass radix (학술적) | DuckDB radix |
|---|---|---|
| **메모리 구조** | 연속 배열 (pre-allocated) | 파티션별 chunk list (동적 성장) |
| **Histogram** | 필수 (크기 사전 결정) | 불필요 |
| **Blocking** | 전체 input 대기 | Streaming (chunk 단위) |
| **Cache 효율** | Scatter 시 연속 접근 보장 | Chunk 내부는 연속, 파티션 간은 아님 |

DuckDB의 trade-off: 연속 메모리 배치의 cache 이점을 포기하는 대신, streaming 파티셔닝이 가능하고 구현이 단순하다. 파티션별 데이터가 chunked storage이므로 external join에서 파티션 단위 접근도 문제없이 동작한다.

---

## 3. Thread-Local 파티셔닝과 Global Merge

### 3.1 Thread-Local 독립 파티셔닝

Sink 단계에서 각 스레드는 **독립적인 thread-local `JoinHashTable`**을 소유한다. 각 thread-local HT는 자체 `sink_collection` (`RadixPartitionedTupleData`)을 갖고, 스레드 간 동기화 없이 각자 16개 파티션에 데이터를 분배한다.

Sink이 끝나면 thread-local HT를 global state의 vector에 등록한다:

```cpp
// physical_hash_join.cpp:516-518
lstate.hash_table->GetSinkCollection().FlushAppendState(lstate.append_state);
auto guard = gstate.Lock();
gstate.local_hash_tables.push_back(std::move(lstate.hash_table));
```

이 시점에서는 merge가 아니라 **포인터를 vector에 push**할 뿐이다. 실제 데이터는 thread-local 메모리 블록에 그대로 남아 있다.

### 3.2 Finalize에서 Global Merge — Zero-Copy

Finalize 단계에서 `JoinHashTable::Merge()`를 통해 thread-local 파티션들을 global로 합친다:

```cpp
// physical_hash_join.cpp:1107-1112 — In-memory 경로
for (auto &local_ht : sink.local_hash_tables) {
    ht.Merge(*local_ht);
}
sink.local_hash_tables.clear();
ht.Unpartition();
```

`Merge()` 내부에서 `PartitionedTupleData::Combine()`이 **파티션 i끼리** 합친다:

```cpp
// partitioned_tuple_data.cpp:241-261
void PartitionedTupleData::Combine(PartitionedTupleData &other) {
    lock_guard<mutex> guard(lock);
    if (partitions.empty()) {
        partitions = std::move(other.partitions);   // 첫 번째: 통째로 move
    } else {
        for (idx_t i = 0; i < other.partitions.size(); i++) {
            partitions[i]->Combine(*other.partitions[i]);  // 파티션 i끼리
        }
    }
    this->count += other.count;
    this->data_size += other.data_size;
}
```

그리고 `TupleDataCollection::Combine()`이 실제 합치기를 수행한다:

```cpp
// tuple_data_collection.cpp:472-484
void TupleDataCollection::Combine(TupleDataCollection &other) {
    if (other.count == 0) return;
    this->segments.reserve(this->segments.size() + other.segments.size());
    for (auto &other_seg : other.segments) {
        AddSegment(std::move(other_seg));   // segment 포인터만 move!
    }
    other.Reset();
}
```

**핵심: 데이터 복사가 전혀 일어나지 않는다.** Segment 포인터를 `std::move`로 옮기는 것이다. Thread-local에서 할당된 buffer block들은 원래 메모리 위치에 그대로 남아 있고, global 파티션의 segment list에 이어붙여질 뿐이다.

```
Global Partition 0의 segments:
  [Seg_Thread1] → [Seg_Thread2] → [Seg_Thread3]   (pointer append)

Global Partition 1의 segments:
  [Seg_Thread1] → [Seg_Thread2] → [Seg_Thread3]

각 Segment는 기존 메모리 블록을 그대로 가리킴 — 데이터 이동 없음
```

Lock 범위는 segment 포인터 append 연산으로 한정되어 매우 짧다.

### 3.3 In-memory Join: 파티셔닝의 해체

메모리에 전체 데이터가 들어가는 in-memory join에서는, global merge 이후 **`Unpartition()`으로 16개 파티션을 하나의 `TupleDataCollection`으로 해체**한다:

```cpp
// join_hashtable.cpp:1678-1680
void JoinHashTable::Unpartition() {
    data_collection = sink_collection->GetUnpartitioned();
}

// partitioned_tuple_data.cpp:317-331
unique_ptr<TupleDataCollection> PartitionedTupleData::GetUnpartitioned() {
    auto data_collection = std::move(partitions[0]);
    partitions[0] = make_uniq<TupleDataCollection>(...);

    for (idx_t i = 1; i < partitions.size(); i++) {
        data_collection->Combine(*partitions[i]);   // segment list 이어붙이기
    }
    return data_collection;
}
```

이것도 **데이터 복사 없음** — 16개 파티션의 segment list를 하나로 연결할 뿐이다. 해체된 단일 `TupleDataCollection` 위에 pointer table (open addressing HT)을 구축하여 probe에 사용한다.

| 시나리오 | Merge 후 동작 | 파티셔닝 상태 |
|----------|--------------|--------------|
| **In-memory** | `Unpartition()` → 단일 collection | **해체** → 단일 HT 구축 |
| **External** | 파티션 유지, 필요시 repartition | 파티션 단위로 HT 구축/probe |

**In-memory join에서 파티셔닝은 최종적으로 무의미해진다.** Sink 중에는 streaming 편의를 위해 16개로 나눠 받지만, Finalize 때 다시 하나로 합쳐서 단일 hash table을 만든다.

### 3.4 전체 흐름 다이어그램

```
[Sink Phase]     각 Thread가 독립적으로 16개 파티션에 streaming append
    │                    (lock 없음, 각자의 sink_collection)
    ▼
[Combine]        sink.local_hash_tables → ht.Merge() 반복
    │                    (segment 포인터 move, 데이터 복사 없음)
    ▼
[In-memory?] ─Yes─→ Unpartition() → 단일 TupleDataCollection
    │                     (segment list 이어붙이기, 복사 없음)
    │                     → pointer table 구축 → Probe
    │
    No (External)
    │
    ▼
[Repartition]    radix bits 증가 (4→7 등), 이때만 실제 데이터 복사 발생
    │                    (DESTROY_AFTER_DONE으로 읽은 즉시 해제)
    ▼
[Round-robin]    파티션 하나씩 메모리에 올려 Build → Probe → 해제
```

---

## 4. 파티션의 물리적 메모리 레이아웃

### 4.1 계층 구조

```
JoinHashTable
└── sink_collection: RadixPartitionedTupleData
    ├── partitions[0]: TupleDataCollection     ← 독립된 TupleDataAllocator 소유
    │   ├── segments[0]: TupleDataSegment      ← Thread 1에서 온 것
    │   │   └── chunks[0..N]: TupleDataChunk
    │   │       └── parts[0..M]: TupleDataChunkPart
    │   │           ├── row_block_index         ← 어느 buffer block인지
    │   │           ├── row_block_offset        ← block 내 시작 위치
    │   │           └── count                   ← 이 part의 row 수
    │   └── segments[1]: TupleDataSegment      ← Thread 2에서 온 것 (Combine 후)
    ├── partitions[1]: TupleDataCollection
    └── ...
```

### 4.2 파티션별 독립 Allocator

각 파티션의 `TupleDataCollection`은 생성 시 **자기만의 `TupleDataAllocator`**를 갖는다:

```cpp
// partitioned_tuple_data.hpp:181-183
unique_ptr<TupleDataCollection> CreatePartitionCollection() {
    return make_uniq<TupleDataCollection>(buffer_manager, layout_ptr, tag, stl_allocator);
}

// tuple_data_collection.cpp:17-24 — 생성자
TupleDataCollection::TupleDataCollection(...)
    : ...
      allocator(make_shared_ptr<TupleDataAllocator>(buffer_manager, layout_ptr, tag, stl_allocator)),
      //         ↑ 파티션마다 새 TupleDataAllocator 생성
```

각 allocator는 자기만의 `row_blocks` 리스트를 관리한다. **파티션끼리 row block을 공유하지 않는다.**

### 4.3 Row Block 내부: 빈틈 없는 연속 배치

하나의 row block은 `BufferManager::Allocate()`로 할당된 **고정 크기 buffer block** (기본 262KB)이다. `BuildChunkPart()`에서 데이터를 채울 때, **현재 block의 끝(`row_block.size`)부터 이어서** 빈틈 없이 배치한다:

```cpp
// tuple_data_allocator.cpp:219-308 — BuildChunkPart()
TupleDataAllocator::BuildChunkPart(..., const idx_t append_count, ...) {
    // block이 비었거나 row 하나도 못 넣으면 새 block 할당
    if (row_blocks.empty() || row_blocks.back().RemainingCapacity() < layout.GetRowWidth()) {
        CreateRowBlock(segment);     // 새 buffer block (262KB)
        if (partition_index.IsValid()) {
            // 파티션 인덱스 기반 eviction 우선순위 태깅 (→ 4.8절 참조)
            row_blocks.back().handle->GetMemory().SetEvictionQueueIndex(
                RadixPartitioning::RadixBits(partition_index.GetIndex()));
        }
    }
    result.row_block_index = row_blocks.size() - 1;
    auto &row_block = row_blocks[result.row_block_index];
    result.row_block_offset = row_block.size;  // 현재 끝 위치부터 시작

    // 남은 공간에 들어갈 수 있는 만큼 채움
    result.count = MinValue(row_block.RemainingCapacity(layout.GetRowWidth()), append_count);
    row_block.size += result.count * layout.GetRowWidth();  // 빈틈 없이 전진
}
```

**여러 input chunk가 와도 같은 block 안에서 연속으로 이어 붙는다.** Input chunk 경계와 row block 내부 배치는 무관하다. Block 생성 시 `SetEvictionQueueIndex()`로 파티션 인덱스에 따른 eviction 우선순위가 태깅된다 (상세 메커니즘은 4.8절).

### 4.4 Fast Path — 기존 ChunkPart 확장

고정 크기 타입(all-constant layout)이고, 현재 chunk에 여유가 있으면 `BuildFastPath()`가 **이전 ChunkPart를 확장**하여 metadata 오버헤드까지 줄인다:

```cpp
// tuple_data_allocator.cpp:114-155 — BuildFastPath()
bool TupleDataAllocator::BuildFastPath(..., const idx_t append_count) {
    if (!layout.AllConstant() || layout.HasDestructor())
        return false;

    auto &chunk = *chunks.back();
    if (chunk.count + append_count > STANDARD_VECTOR_SIZE)
        return false;                      // chunk 2048개 초과하면 불가

    auto &part = *segment.chunk_parts[chunk.part_ids.End() - 1];
    auto &row_block = row_blocks[part.row_block_index];

    const auto added_size = append_count * row_width;
    if (row_block.size + added_size > row_block.capacity)
        return false;                      // block에 공간 없으면 불가

    // 이전 part 바로 뒤에 이어서 포인터 설정
    const auto base_row_ptr = GetRowPointer(pin_state, part) + part.count * row_width;
    for (idx_t i = 0; i < append_count; i++) {
        row_locations[append_offset + i] = base_row_ptr + i * row_width;
    }

    chunk.count += append_count;
    part.count += append_count;   // 기존 part의 count 증가 (새 part 생성 안 함)
    row_block.size += added_size;
    return true;
}
```

Fast path가 성공하면 새 `TupleDataChunkPart`를 생성하지 않고 기존 part를 확장한다. 연속된 input chunk들이 **하나의 part로 합쳐져** metadata가 최소화된다.

### 4.5 물리적 메모리 다이어그램

한 스레드의 한 파티션에 대한 물리적 메모리 배치:

```
Partition P의 TupleDataAllocator:

row_blocks[0]: Buffer Block (262KB)
┌───────────────────────────────────────────────────────┐
│ Row₀ │ Row₁ │ Row₂ │ ... │ Row_N │                   │
│←── input chunk 1 ──→│←─ chunk 2 ─→│← chunk 3 →│     │
│              빈틈 없이 연속 append                     │
│                                          ↑ row_block.size
└───────────────────────────────────────────────────────┘

row_blocks[1]: Buffer Block (262KB)    ← block 0이 가득 차면 새 block 할당
┌───────────────────────────────────────────────────────┐
│ Row_{N+1} │ Row_{N+2} │ ...                           │
└───────────────────────────────────────────────────────┘

두 block 사이는 물리적으로 불연속 (별도 buffer allocation)
```

각 row의 내부 구조:

```
┌── 하나의 row ──────────────────────────────────────────┐
│ [Validity] [Key cols (fixed)] [Payload cols] [hash 8B] │
│                                                         │
│ Variable-length 데이터(VARCHAR 등)는 별도 heap block에  │
│ 저장되며, row에는 pointer만 보관                        │
└─────────────────────────────────────────────────────────┘
```

### 4.6 Unpartition 후 최종 레이아웃

In-memory join에서 `Unpartition()` 후의 최종 상태:

```
data_collection: TupleDataCollection (단일)
├── segments[0] (Thread 1, Partition 0에서 온 것)
│   └── row_blocks → [Block A: Row₀..Row_K]
├── segments[1] (Thread 1, Partition 1에서 온 것)
│   └── row_blocks → [Block B: Row₀..Row_M]
├── segments[2] (Thread 2, Partition 0에서 온 것)
│   └── row_blocks → [Block C: Row₀..Row_J]
├── ...
└── segments[N]

이 위에 pointer table (open addressing HT)이 구축됨:
┌────────────────────────────────────┐
│ ht_entry_t[0] → Row ptr + salt    │  ← hash & bitmask로 인덱싱
│ ht_entry_t[1] → Row ptr + salt    │
│ ...                                │
│ ht_entry_t[capacity]               │
└────────────────────────────────────┘
```

Segments는 원래 할당된 buffer block에 **그대로** 있으며, 서로 다른 스레드/파티션에서 온 segment들이 물리적으로 연속이 아니다. 논리적으로 하나의 collection으로 묶여 있을 뿐이다.

### 4.7 정리

| 속성 | 답변 |
|------|------|
| 한 파티션의 한 block 안에서 연속인가? | **Yes.** `row_block_offset = row_block.size`로 빈틈 없이 연속 배치 |
| Input chunk마다 따로 모이는가? | **No.** 같은 block 안에서 이전 input 바로 뒤에 이어서 채움 |
| Block 간에도 연속인가? | **No.** 각 buffer block은 `BufferManager::Allocate()`로 별도 할당 |
| 파티션끼리 block을 공유하는가? | **No.** 파티션마다 독립 `TupleDataAllocator`와 자체 `row_blocks` |
| 학술적 radix join과의 비교 | 학술적: single contiguous array / DuckDB: **piecewise-contiguous** (block 단위 연속) |

### 4.8 Spill과 Eviction: Buffer Manager 위임

DuckDB는 **명시적으로 파티션을 디스크에 쓰는 코드가 없다.** Build-side spill은 buffer manager의 eviction 메커니즘에 완전히 위임된다. 파티션별 독립 allocator 설계(4.2절)가 이를 가능하게 한다.

#### Block = 파티션 단위

파티션마다 독립 `TupleDataAllocator`가 자체 `row_blocks`를 관리하므로, **하나의 buffer block에는 오직 하나의 파티션의 row들만 존재한다.** Block 단위 eviction이 곧 파티션 단위 eviction이 되며, 무관한 파티션의 데이터가 함께 내려가는 낭비가 없다.

#### Eviction Queue Index — 파티션 기반 우선순위

Block 할당 시 `SetEvictionQueueIndex(RadixPartitioning::RadixBits(partition_index))`로 eviction 우선순위를 태깅한다 (4.3절 코드 참조). `RadixBits()`는 `log2(partition_index)`를 반환하여 파티션 번호를 대수적으로 queue에 매핑한다:

```cpp
// radix_partitioning.hpp:34-36
template <class T>
static inline idx_t RadixBits(T n) {
    return sizeof(T) * 8 - CountZeros<T>::Leading(n);  // ≈ log2(n)
}
```

Buffer pool은 `MANAGED_BUFFER_QUEUE_SIZE = 6`개의 eviction queue를 갖고, queue index가 높을수록 **먼저 evict**된다:

```cpp
// buffer_pool.cpp:284-302
EvictionQueue &BufferPool::GetEvictionQueueForBlockMemory(const BlockMemory &memory) {
    const auto &queue_size = eviction_queue_sizes[handle_queue_type_idx];  // = 6
    auto eviction_queue_idx = memory.GetEvictionQueueIndex();
    if (eviction_queue_idx < queue_size) {
        queue_index += queue_size - eviction_queue_idx - 1;
        // idx 0 → queue 5 (마지막 evict = 가장 안전)
        // idx 5 → queue 0 (먼저 evict)
    }
}
```

| 파티션 인덱스 | `RadixBits()` 값 | Eviction 우선순위 |
|-------------|-----------------|-----------------|
| 0 | 0 | **가장 낮음** (마지막에 evict) |
| 1 | 1 | 낮음 |
| 2~3 | 2 | 중간 |
| 4~7 | 3 | 중간 |
| 8~15 | 4 | 높음 |
| 16~63 | 5~6 | **가장 높음** (먼저 evict) |

#### 메모리 부족 시 동작 흐름

Sink 중 `FlushAppendState()`가 buffer pin을 해제하면, 해당 block은 eviction queue에 진입한다. 이후 메모리가 부족해지면 buffer manager가 **높은 인덱스 파티션의 block부터 자동으로 디스크로 evict**한다:

```
메모리 부족 발생
    ↓
BufferPool이 eviction queue에서 block 선택
    ↓
높은 파티션 번호의 block부터 evict (queue index 순)
    ↓
block 내용이 디스크로 swap out (buffer manager 내부 처리)
    ↓
메모리 확보
    ↓
나중에 해당 파티션 처리 시 re-pin → 디스크에서 자동 로드
```

hash join 코드에는 파일 I/O 호출이 전혀 없다. 모든 spill/reload는 buffer manager의 pin/unpin 인터페이스를 통해 투명하게 처리된다.

#### PrepareExternalFinalize와의 연동

`PrepareExternalFinalize()` (6.4절)는 처리할 파티션을 선택할 때 **낮은 인덱스 파티션을 우선** 선택한다. 이는 eviction 우선순위와 정합된다:

- 낮은 번호 파티션 → eviction 우선순위 낮음 → **메모리에 남아 있을 확률 높음** → 먼저 처리하면 re-load I/O 최소화
- 높은 번호 파티션 → 이미 evict되었을 확률 높음 → 나중에 처리

소스 코드 코멘트가 이를 명시한다:

```cpp
// join_hashtable.cpp:1782-1783
// Retaining as much of the original order as possible reduces I/O
// (partition idx determines eviction queue idx)
```

#### 정리

| 질문 | 답변 |
|------|------|
| 명시적 spill 코드가 있는가? | **No.** Buffer manager의 eviction에 위임 |
| Block eviction 시 한 파티션만 영향받는가? | **Yes.** 파티션당 독립 allocator → block = 단일 파티션 |
| 같은 파티션의 block들이 함께 evict되는가? | **경향적으로 Yes.** 같은 eviction queue에 있으므로 함께 evict될 확률이 높지만, atomic한 보장은 없음 |
| 다시 올릴 때는? | `PrepareExternalFinalize()`에서 해당 파티션의 segments를 `Combine()`으로 가져오면, 이후 접근 시 buffer manager가 자동 re-pin |
| 처리 순서와 eviction 우선순위가 정합되는가? | **Yes.** 낮은 번호 파티션부터 처리 = 아직 메모리에 있을 확률이 높은 것부터 처리 |

---

## 5. 파티션 수 결정과 Repartitioning

### 5.1 초기 파티션: 고정 16개

Sink 단계에서는 `INITIAL_RADIX_BITS = 4`(16 파티션)로 고정한다. 파티션 수에 대한 고민 없이 데이터를 즉시 분배한다.

### 5.2 Finalize에서 메모리 비교

모든 build input이 도착한 후 `PrepareFinalize()` (`physical_hash_join.cpp:602-617`)에서 처음으로 메모리 적합성을 판단한다:

```cpp
// physical_hash_join.cpp:606-607
gstate.total_size = ht.GetTotalSize(
    gstate.local_hash_tables, gstate.max_partition_size, gstate.max_partition_count);

// physical_hash_join.cpp:1050
sink.external = (reservation < sink.total_size);  // 메모리 부족?
```

**메모리 충분 (in-memory join):**
```cpp
// join_hashtable.cpp:1678-1680 — Unpartition()
data_collection = sink_collection->GetUnpartitioned();  // 16개를 하나로 합침
```

**메모리 부족 (external join):** repartition으로 전환.

### 5.3 SetRepartitionRadixBits — 새 radix bits 결정

```cpp
// join_hashtable.cpp:1682-1707 — SetRepartitionRadixBits()
for (added_bits = 1; added_bits < max_added_bits; added_bits++) {
    partition_multiplier = NumberOfPartitions(added_bits);
    new_estimated_ht_size = max_partition_size / partition_multiplier + pointer_table;

    if (new_estimated_ht_size <= max_ht_size / 4) {  // 목표: 가용 메모리의 1/4
        break;
    }
}
radix_bits += added_bits;  // 예: 4→7이면 128 파티션
```

가장 큰 파티션이 가용 메모리의 약 1/4에 들어올 때까지 radix bits를 1씩 증가시킨다.

### 5.4 Repartition 상세 동작

`HashJoinRepartitionEvent` (`physical_hash_join.cpp:787-861`)가 각 thread-local HT에 대해 병렬로 `Repartition()` 태스크를 생성한다:

```cpp
// physical_hash_join.cpp:830-836
for (auto &local_ht : local_hts) {
    partition_tasks.push_back(
        make_uniq<HashJoinRepartitionTask>(..., *sink.hash_table, *local_ht, ...));
}
```

`Repartition()` (`partitioned_tuple_data.cpp:272-305`)의 핵심:

```cpp
for (partition_idx = 0; partition_idx < partitions.size(); partition_idx++) {  // 기존 16개 순회
    TupleDataChunkIterator iterator(partition, DESTROY_AFTER_DONE, true);
    do {
        new_partitioned_data.Append(append_state, chunk_state, ...);  // hash 상위 7비트로 재배치
    } while (iterator.Next());

    RepartitionFinalizeStates(*this, new_partitioned_data, append_state, partition_idx);
    partitions[partition_idx]->Reset();  // 기존 파티션 메모리 즉시 해제
}
```

**Repartitioning의 핵심 속성:**

1. **Hash 재계산 불필요**: 각 row에 hash 값이 이미 저장되어 있으므로 (`[keys | payload | found_match | hash]`) 상위 비트를 더 많이 사용하기만 하면 됨
2. **계층적 분할**: radix bits가 4→7로 증가하면 기존 파티션이 정확히 세분화됨
3. **`DESTROY_AFTER_DONE`**: 읽은 기존 파티션은 즉시 메모리 해제 → 메모리 부족 상황에서도 동작 가능
4. **병렬 수행**: 각 thread-local HT가 독립적으로 repartition

파티션 매핑 예시 (4→7 bits, 16→128 파티션):

```
old partition 0  →  new partition 0, 1, 2, 3, 4, 5, 6, 7
old partition 1  →  new partition 8, 9, 10, 11, 12, 13, 14, 15
...
old partition 15 →  new partition 120, 121, ..., 127
```

`RepartitionFinalizeStates()` (`radix_partitioning.cpp:242-266`)가 이 매핑을 관리한다:

```cpp
multiplier = NumberOfPartitions(new_radix_bits - old_radix_bits);  // 2^(7-4) = 8
from_idx = finished_partition_idx * multiplier;   // old partition 0 → new 0~7
to_idx = from_idx + multiplier;
```

기존 파티션 하나의 처리가 완료되면 대응하는 새 파티션들의 append state를 즉시 finalize하여 메모리 pin을 해제한다.

### 5.5 전체 타임라인

```
[Sink]          [Finalize]              [External Join]
  │                 │                        │
  ▼                 ▼                        ▼
16 파티션으로     전체 크기 확인 →           파티션 하나씩
streaming       메모리 비교 →              메모리에 올려서
append          필요시 repartition →       build → probe
                (16 → 128 등)
```

| 시점 | 파티션 수 | 결정 근거 |
|------|-----------|-----------|
| Sink (streaming) | **16** (고정) | `INITIAL_RADIX_BITS = 4` 하드코딩 |
| Finalize | 16 또는 **증가** | 실제 데이터 크기 vs 가용 메모리 |
| External Join 중 | 유지 | 파티션별 순차 처리 |

---

## 6. Probe-Side 파티셔닝 (ProbeAndSpill)

### 6.1 별도 파티셔닝 패스 없음

Probe 측은 별도의 파티셔닝 단계가 없다. Probe 데이터가 streaming으로 들어오면서 **probe와 spill이 동시에 수행**된다.

`ProbeAndSpill()` (`join_hashtable.cpp:1809-1845`)가 핵심이다:

```cpp
void JoinHashTable::ProbeAndSpill(...) {
    // 1) hash 계산
    Hash(probe_keys, ..., hashes);

    // 2) 현재 활성 파티션에 해당하는 row와 아닌 row를 분리
    true_count = RadixPartitioning::Select(
        hashes, ..., radix_bits,
        current_partitions,     // 현재 메모리에 올라온 파티션 mask
        &true_sel, &false_sel   // true = 지금 probe, false = spill
    );

    // 3) 비활성 파티션 → spill (파티셔닝)
    spill_chunk.Slice(false_sel, false_count);
    probe_spill.Append(spill_chunk, spill_state);   // RadixPartitionedColumnData에 append

    // 4) 활성 파티션 → 즉시 probe
    probe_keys.Slice(true_sel, true_count);
    GetRowPointers(...);  // hash table 조회
}
```

`RadixPartitioning::Select()` (`radix_partitioning.cpp:78-81`)는 hash의 상위 비트로 파티션 인덱스를 계산한 후, `current_partitions` validity mask와 비교하여 활성/비활성을 분류한다:

```cpp
// radix_partitioning.cpp:63-76 — SelectFunctor
[&](const hash_t hash) {
    const auto partition_idx = CONSTANTS::ApplyMask(hash);
    return partition_mask.RowIsValidUnsafe(partition_idx);  // 활성 파티션이면 true
}
```

한 chunk 안에서 probe와 spill(파티셔닝)이 동시에 발생한다. 별도의 파티셔닝 패스가 없으므로 비용은 `RadixPartitioning::Select()` 한 번(bitmask + shift)으로 거의 무시할 수 있다.

### 6.2 ProbeSpill 구조

```cpp
// join_hashtable.cpp:1847-1850 — ProbeSpill 생성
global_partitions = make_uniq<RadixPartitionedColumnData>(
    context, probe_types,
    ht.radix_bits,              // build와 동일한 radix bits (예: 7 = 128 파티션)
    probe_types.size() - 1      // hash column index
);
```

ProbeSpill은 build와 **동일한 radix bits**의 `RadixPartitionedColumnData`이다. Build의 repartition이 이미 끝난 상태이므로 최종 radix bits를 알고 있고, probe 데이터를 처음부터 올바른 granularity로 나눌 수 있다.

### 6.3 PrepareNextProbe — 라운드별 재사용

이후 `PrepareNextProbe()` (`join_hashtable.cpp:1885-1908`)에서 현재 활성 파티션의 spill data만 꺼낸다:

```cpp
void ProbeSpill::PrepareNextProbe() {
    auto &partitions = global_partitions->GetPartitions();
    for (partition_idx = 0; ...) {
        if (!ht.current_partitions.RowIsValidUnsafe(partition_idx)) {
            continue;  // 비활성 파티션은 건너뜀
        }
        // 현재 활성 파티션의 spill data만 꺼냄
        global_spill_collection->Combine(*partition);
        partition.reset();  // 메모리 해제
    }
    consumer = make_uniq<ColumnDataConsumer>(*global_spill_collection, ...);
}
```

### 6.4 External Join 전체 흐름

#### PrepareExternalFinalize — 파티션 선택 전략

`PrepareExternalFinalize()` (`join_hashtable.cpp:1747-1807`)는 다음 라운드에서 처리할 파티션들을 선택한다. 핵심은 **작은 파티션부터, 그리고 원래 인덱스 순서를 최대한 유지**하는 것이다:

```cpp
// join_hashtable.cpp:1777-1801
// 파티션을 크기 순으로 정렬하되, 원래 순서를 최대한 유지
std::stable_sort(partition_indices.begin(), partition_indices.end(), [&](...) {
    // min_partition_size로 나눠서 비슷한 크기의 파티션들은 원래 순서 유지
    // Retaining as much of the original order as possible reduces I/O
    // (partition idx determines eviction queue idx)
    return lhs_size / min_partition_size < rhs_size / min_partition_size;
});

// 가용 메모리에 들어갈 때까지 파티션 추가
for (const auto &partition_idx : partition_indices) {
    const auto incl_ht_size = data_size + partitions[partition_idx]->SizeInBytes()
                            + PointerTableSize(incl_count);
    if (count > 0 && incl_ht_size > max_ht_size) {
        break;  // 메모리 초과 → 여기서 멈춤 (최소 1개는 항상 추가)
    }
    current_partitions.SetValidUnsafe(partition_idx);
    data_collection->Combine(*partitions[partition_idx]);  // 활성 파티션 → 메인 collection으로
    completed_partitions.SetValidUnsafe(partition_idx);
}
```

원래 인덱스 순서를 유지하는 이유: **낮은 인덱스 파티션의 buffer block은 eviction 우선순위가 낮아 메모리에 남아 있을 확률이 높기 때문이다** (4.8절). 이 순서대로 처리하면 re-load I/O가 최소화된다.

```
Build 완료 + Repartition 완료 (예: 128 파티션)
         │
         ▼
PrepareExternalFinalize: 메모리에 들어가는 만큼 파티션 선택
   - 작은 파티션부터, 원래 인덱스 순서 우선 (eviction 우선순위와 정합)
   예: 파티션 [0,1,2,3] 활성화 (current_partitions mask)
         │
         ▼
    ┌──────────── 1st Probe Pass (LHS pipeline streaming) ─────────────┐
    │                                                                    │
    │  chunk 도착 → ProbeAndSpill()                                     │
    │     hash ∈ {0,1,2,3}  →  즉시 probe, 결과 출력                   │
    │     hash ∈ {4..127}   →  ProbeSpill에 append (해당 파티션으로)     │
    │                                                                    │
    └────────────────────────────────────────────────────────────────────┘
         │
         ▼  LHS 전체 소진
    ProbeSpill.Finalize()  ← thread-local spill들을 global로 병합
         │
         ▼
    ┌─── 2nd Round: 파티션 [4,5,6,7] ───┐
    │  PrepareExternalFinalize:          │
    │    파티션 4~7의 build data로       │
    │    HT 재구축                       │
    │  PrepareNextProbe:                  │
    │    ProbeSpill에서 파티션 4~7의       │
    │    spill data만 꺼내옴               │
    │  → probe (spill된 데이터 대상)       │
    └────────────────────────────────────┘
         │
         ▼  ... 파티션 [8..11] → ... → [124..127]
         │
         ▼
       DONE
```

---

## 7. Classic Radix Join과의 비교

### 7.1 Classic Radix Join (Boncz, Manegold, ICDE 1999)

```
목적: TLB/cache 최적화

Pass 1: radix 상위 비트로 파티셔닝  →  각 파티션이 L2 cache에 fit
Pass 2: radix 하위 비트로 파티셔닝  →  각 sub-파티션이 L1 cache에 fit

Build: 파티션 내부에서 HT 구축  →  cache-resident, TLB miss 최소
Probe: 같은 파티션끼리 매칭     →  cache-resident, TLB miss 최소
```

핵심은 **multi-pass partitioning으로 build/probe 양쪽 모두를 cache-sized 단위로 분할**하여, hash table build와 probe가 전부 cache 안에서 이루어지게 하는 것이다. 파티셔닝 자체의 TLB miss도 pass를 나눠서 제어한다 (한 pass에서 scatter하는 파티션 수 = TLB 엔트리 수 이내).

### 7.2 DuckDB의 목적: 메모리 관리

```
목적: 메모리 관리 (external hash join)

- 메모리에 안 들어가면 → 파티션 단위로 spill/reload
- 파티션 수 부족하면 → radix bits 증가로 세분화 (repartition)
```

DuckDB가 radix 방식을 택한 이유는 **TLB 최적화가 아니라 repartitioning의 용이성**이다:

| 속성 | `hash % N` | radix (상위 비트) |
|------|-----------|-------------------|
| 파티션 수 변경 | 전체 rehash 필요 | **비트만 추가하면 기존 파티션이 정확히 분할됨** |
| 예: 16→128 | 모든 row 재계산 | 파티션 0 → {0..7}, 파티션 1 → {8..15}, ... |
| Hash 재계산 | 필요 | **불필요** (저장된 hash의 상위 비트만 더 읽으면 됨) |

### 7.3 TLB Miss를 무시하는 이유

`ProbeAndSpill()`에서 128개 파티션으로 동시에 scatter하면 classic radix join이 해결하려던 TLB thrashing이 그대로 발생한다. DuckDB는 이를 **의도적으로 무시**한다.

이유: External join은 이미 **디스크 I/O가 dominant cost**이다. TLB miss는 수십 ns, disk I/O는 수십~수백 μs. 파티셔닝의 cache 효율은 의미 없는 수준이다.

### 7.4 In-memory에서의 차이

In-memory join(일반적인 케이스)에서 DuckDB는 파티셔닝을 전혀 활용하지 않는다. `Unpartition()`으로 16개를 하나로 합쳐서 단일 hash table을 구축한다. Cache 효율은 vectorized execution (2048-tuple batch)으로 따로 확보한다.

### 7.5 정리

| | Classic Radix Join (Boncz) | DuckDB Radix Partitioning |
|---|---|---|
| **목적** | TLB/cache locality 최적화 | 메모리 관리 (grace hash join) |
| **파티셔닝** | Multi-pass (histogram → scatter) | Single-pass streaming (chunked append) |
| **Build/Probe 양쪽** | 양쪽 모두 cache-sized로 분할 | Build만 사전 파티셔닝, Probe는 동시 수행 |
| **In-memory** | 항상 파티셔닝 활용 | `Unpartition()`으로 무시 |
| **External** | N/A (in-memory 전용 기법) | 파티션 단위 spill/reload |
| **TLB miss 고려** | 핵심 목표 | 무시 (I/O dominant) |
| **Repartition** | 고정 파티션 수 | 동적 radix bits 증가 |

DuckDB에서 "radix"는 "cache-conscious partitioned hash join"이 아니라 "**비트 기반으로 계층적 분할이 가능한 파티셔닝 방식**"을 의미하며, 그 용도는 순전히 grace hash join의 메모리 관리이다.

---

## 8. Key References

### 소스 코드 경로

| 파일 | 주요 함수/구조체 | 역할 |
|------|------------------|------|
| `src/execution/join_hashtable.cpp` | `Build()` (L383-456), `AppendUnified` (L455) | Build-side streaming 파티셔닝 |
| `src/execution/join_hashtable.cpp` | `SetRepartitionRadixBits()` (L1682-1707) | 새 radix bits 결정 |
| `src/execution/join_hashtable.cpp` | `ProbeAndSpill()` (L1809-1845) | Probe + spill 동시 수행 |
| `src/execution/join_hashtable.cpp` | `PrepareExternalFinalize()` (L1747-1807) | 활성 파티션 선택 |
| `src/include/duckdb/execution/join_hashtable.hpp` | `INITIAL_RADIX_BITS` (L380), `ProbeSpill` 클래스 | 상수 정의, probe spill 구조 |
| `src/common/types/row/partitioned_tuple_data.cpp` | `Repartition()` (L272-305) | 파티션 세분화 실행 |
| `src/common/types/row/partitioned_tuple_data.cpp` | `RepartitionFinalizeStates()` (L242-266) | Old→new 파티션 매핑, pin 해제 |
| `src/common/types/row/radix_partitioning.cpp` | `ComputePartitionIndicesFunctor` (L84-91) | Hash → 파티션 인덱스 계산 |
| `src/common/types/row/radix_partitioning.cpp` | `RadixPartitioningConstants` (L10-25) | MASK, SHIFT, NUM_PARTITIONS 상수 |
| `src/common/types/row/radix_partitioning.cpp` | `SelectFunctor` (L63-76), `Select()` (L78-81) | Probe-side active/spill 분리 |
| `src/execution/operator/join/physical_hash_join.cpp` | `PrepareFinalize()` (L602-617) | 메모리 적합성 판단 |
| `src/execution/operator/join/physical_hash_join.cpp` | Finalize external 판단 (L1050) | `reservation < total_size` 비교 |
| `src/execution/operator/join/physical_hash_join.cpp` | `HashJoinRepartitionEvent` (L787-861) | 병렬 repartition 이벤트 |
| `src/execution/operator/join/physical_hash_join.cpp` | Finalize: `Merge()` 루프 + `Unpartition()` (L1107-1112) | Thread-local → global merge, 파티션 해체 |
| `src/execution/operator/join/physical_hash_join.cpp` | `local_hash_tables.push_back()` (L518) | Thread-local HT 등록 |
| `src/common/types/row/partitioned_tuple_data.cpp` | `Combine()` (L241-261) | 파티션별 zero-copy merge (segment pointer move) |
| `src/common/types/row/partitioned_tuple_data.cpp` | `GetUnpartitioned()` (L317-331) | 16개 파티션 → 단일 collection 해체 |
| `src/common/types/row/tuple_data_collection.cpp` | `Combine()` (L472-484), `AddSegment()` (L486-491) | Segment 포인터 move (데이터 복사 없음) |
| `src/common/types/row/tuple_data_allocator.cpp` | `BuildChunkPart()` (L219-308) | Row block 내 연속 배치, block 할당 |
| `src/common/types/row/tuple_data_allocator.cpp` | `BuildFastPath()` (L114-155) | 기존 ChunkPart 확장 (metadata 최소화) |
| `src/common/types/row/tuple_data_segment.hpp` | `TupleDataChunkPart` (L25-59) | row_block_index, row_block_offset, count |
| `src/include/duckdb/common/radix_partitioning.hpp` | `RadixPartitionedTupleData` (L108-138) | Radix 파티셔닝 구현, `Initialize()` |
| `src/common/radix_partitioning.cpp` | `RadixPartitionedTupleData::Initialize()` (L191-197) | 파티션별 독립 `TupleDataCollection` 생성 |
| `src/include/duckdb/common/types/row/partitioned_tuple_data.hpp` | `CreatePartitionCollection()` (L181-183) | 파티션별 독립 allocator 생성 |
| `src/common/types/row/tuple_data_allocator.cpp` | `BuildChunkPart()` 내 `SetEvictionQueueIndex()` (L231-233) | Block 할당 시 파티션 기반 eviction 우선순위 태깅 |
| `src/include/duckdb/common/radix_partitioning.hpp` | `RadixBits()` (L34-36) | `log2(partition_index)` → eviction queue index 계산 |
| `src/include/duckdb/storage/buffer/block_handle.hpp` | `SetEvictionQueueIndex()` (L174-180) | Block 단위 eviction queue index 설정 |
| `src/storage/buffer/buffer_pool.cpp` | `GetEvictionQueueForBlockMemory()` (L284-303) | Eviction queue 선택 (index 기반 우선순위) |
| `src/execution/join_hashtable.cpp` | `PrepareExternalFinalize()` (L1747-1807) | 활성 파티션 선택 (크기 + 인덱스 순서 기반) |

### 논문 및 참고 문헌

1. **"Main-Memory Hash Joins on Multi-Core CPUs: Tuning to the Underlying Hardware"** — Stefan Manegold, Peter Boncz, ICDE 1999. Classic radix join의 원 논문. TLB/cache 최적화를 위한 multi-pass radix partitioning.

2. **"Saving Private Hash Join: How to Implement an External Hash Join within Limited Memory"** — Kuiper et al., VLDB 2024. DuckDB의 external hash join 구현에 직접적으로 적용된 논문. 파티션 단위 build-probe 순환과 dynamic repartitioning 전략.

3. **"Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age"** — Viktor Leis, Peter Boncz, Alfons Kemper, Thomas Neumann, SIGMOD 2014. DuckDB의 morsel 단위 병렬 실행 모델의 이론적 기반.
