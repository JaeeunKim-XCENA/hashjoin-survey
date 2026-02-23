# Apache Arrow Acero — Partitioning 전략 심층 분석

## 요약

Acero의 Hash Join에서 partitioning은 **병렬 build를 위한 lock-free 작업 분할**이 핵심 목적이다. DuckDB처럼 메모리 부족 시 spill-to-disk를 위한 grace hash join용 파티셔닝이 아니라, build phase에서 여러 스레드가 충돌 없이 독립적인 Swiss Table을 구축할 수 있도록 hash 공간을 분할하는 데 사용된다.

핵심 특성:
- **Build-only partitioning**: Build 측만 파티셔닝하며, probe 측은 merge된 단일 글로벌 hash table에 대해 직접 조회
- **Hash 상위 비트 기반 파티셔닝**: Swiss Table의 block id 결정과 동일한 비트 영역을 사용하여 merge 시 자연스러운 매핑
- **Partition-per-SwissTable**: 각 partition이 독립적인 `SwissTableWithKeys`를 보유하므로 build 시 lock 불필요
- **3단계 build pipeline**: Partition → Build → Merge 순서로 진행되며, merge 후 단일 글로벌 hash table이 생성됨
- **Spill-to-disk 미지원**: 모든 build 데이터가 메모리에 상주해야 하므로, partitioning의 목적은 순수하게 병렬성 확보

---

## 1. Partitioning 개요

### 1.1 파티션 수 결정

파티션 수는 `SwissTableForJoinBuild::Init()`(`swiss_join.cc:1102-1154`)에서 두 가지 요인을 고려하여 결정된다:

```cpp
// swiss_join.cc:1114-1118
constexpr int64_t min_num_rows_per_prtn = 1 << 12;  // 4096
log_num_prtns_ =
    std::min(bit_util::Log2(dop_),
             bit_util::Log2(bit_util::CeilDiv(num_rows, min_num_rows_per_prtn)));
num_prtns_ = 1 << log_num_prtns_;
```

**결정 논리:**
- `log2(DOP)`: 스레드 수(Degree of Parallelism)의 log2. 파티션이 스레드 수보다 많으면 비효율적이므로 상한
- `log2(ceil(num_rows / 4096))`: 파티션당 최소 4096 행을 보장. 행이 너무 적으면 파티셔닝 오버헤드가 이점을 초과
- 두 값 중 **작은 값**을 선택

**예시:**
| DOP | Build 행 수 | log_num_prtns | 파티션 수 |
|-----|------------|---------------|-----------|
| 8 | 100,000 | min(3, 4) = 3 | 8 |
| 16 | 100,000 | min(4, 4) = 4 | 16 |
| 16 | 10,000 | min(4, 1) = 1 | 2 |
| 4 | 1,000,000 | min(2, 7) = 2 | 4 |
| 1 | any | min(0, x) = 0 | 1 |

파티션 수는 항상 **2의 거듭제곱**이다. 이는 hash 비트 기반 파티셔닝과 Swiss Table의 block 구조가 2의 거듭제곱 단위로 동작하기 때문이다.

### 1.2 Hash 기반 파티션 분배

파티셔닝은 32비트 hash 값의 **최상위 비트**를 사용한다. 이는 Swiss Table이 block id를 결정할 때 hash의 최상위 비트를 사용하는 방식과 의도적으로 일치시킨 것이다.

```cpp
// key_map_internal.h:108-110
static uint32_t block_id_from_hash(uint32_t hash, int log_blocks) {
    return hash >> (bits_hash_ - log_blocks);  // 32 - log_blocks만큼 우측 shift
}
```

파티셔닝에서는:
```cpp
// swiss_join.cc:1193
return batch_state.hashes[i] >> (SwissTable::bits_hash_ - log_num_prtns_);
```

즉, hash의 최상위 `log_num_prtns_` 비트가 파티션 인덱스가 된다. 파티셔닝 후에는 사용한 상위 비트를 제거하기 위해 hash를 왼쪽으로 shift한다:

```cpp
// swiss_join.cc:1202-1204
for (size_t i = 0; i < batch_state.hashes.size(); ++i) {
    batch_state.hashes[i] <<= log_num_prtns_;
}
```

이 shift의 의미는 다음과 같다: 파티션 내부의 Swiss Table은 이미 파티션 범위로 제한된 hash 공간을 다루므로, 파티션 구분에 사용된 상위 비트는 더 이상 필요 없다. 남은 비트만으로 Swiss Table의 block id와 stamp를 결정하면 hash collision이 줄어든다.

---

## 2. Build-Side Partitioning

Build-side partitioning은 3단계 파이프라인(Partition → Build → Merge)으로 구성된다.

### 2.1 Phase 1: PartitionBatch (배치별 병렬)

`SwissTableForJoinBuild::PartitionBatch()`(`swiss_join.cc:1156-1208`)는 각 build 배치를 hash 기반으로 partition별로 분류한다.

**처리 흐름:**

1. **Hash 계산**: `Hashing32::HashBatch()`로 배치 내 모든 행의 32비트 hash를 계산하고, `batch_state.hashes`에 보존 (build phase에서 재사용)
2. **PartitionSort**: hash 상위 비트로 파티션 인덱스를 결정하고, `PartitionSort::Eval()`로 행을 파티션별로 정렬
3. **Hash 조정**: 파티셔닝에 사용한 상위 비트를 제거 (left shift)

**PartitionSort의 동작 원리:**

`PartitionSort::Eval()`(`partition_util.h:64-89`)은 O(n) counting sort 기반의 bucket sort이다:

```cpp
// partition_util.h:64-89
template <class INPUT_PRTN_ID_FN, class OUTPUT_POS_FN>
static void Eval(int64_t num_rows, int num_prtns, uint16_t* prtn_ranges,
                 INPUT_PRTN_ID_FN prtn_id_impl, OUTPUT_POS_FN output_pos_impl) {
    // 1. 각 파티션별 행 수를 카운트
    for (int64_t i = 0; i < num_rows; ++i) {
        int prtn_id = prtn_id_impl(i);
        ++prtn_ranges[prtn_id + 1];
    }
    // 2. Exclusive prefix sum으로 변환
    uint16_t sum = 0;
    for (int i = 0; i < num_prtns; ++i) {
        uint16_t sum_next = sum + prtn_ranges[i + 1];
        prtn_ranges[i + 1] = sum;
        sum = sum_next;
    }
    // 3. 각 행을 해당 파티션의 정렬된 위치에 배치
    for (int64_t i = 0; i < num_rows; ++i) {
        int prtn_id = prtn_id_impl(i);
        int pos = prtn_ranges[prtn_id + 1]++;
        output_pos_impl(i, pos);
    }
}
```

결과물은 두 가지이다:
- `prtn_ranges`: 파티션별 행 범위 (exclusive cumulative sum). `prtn_ranges[p]`부터 `prtn_ranges[p+1]`까지가 파티션 p의 행
- `prtn_row_ids`: 파티션 순서로 정렬된 원래 배치의 행 인덱스

**단일 파티션 최적화:**

파티션이 1개일 때(`num_prtns_ == 1`)는 `PartitionSort::Eval()` 호출을 생략하고 단순히 0..N-1 순서의 identity mapping을 사용한다 (`swiss_join.cc:1176-1184`).

**BatchState 구조:**

각 배치의 파티셔닝 결과는 `BatchState`에 저장되어 build phase에서 재사용된다:

```cpp
// swiss_join_internal.h:617-626
struct BatchState {
    std::vector<uint32_t> hashes;        // 행별 hash (재계산 방지)
    std::vector<uint16_t> prtn_ranges;   // 파티션별 범위 (num_prtns + 1개)
    std::vector<uint16_t> prtn_row_ids;  // 파티션 순서로 정렬된 행 인덱스
};
```

**Task 병렬성:**

Partition phase의 task 수는 `build_side_batches_.batch_count()`이다 (`swiss_join.cc:2594-2595`). 각 배치가 독립적인 task로 실행되며, 배치 간 의존성이 없으므로 완전 병렬 처리가 가능하다.

### 2.2 Phase 2: ProcessPartition (파티션별 병렬)

`SwissTableForJoinBuild::ProcessPartition()`(`swiss_join.cc:1210-1254`)는 각 파티션에 대해, **모든 배치**의 해당 파티션 행을 하나의 독립적인 Swiss Table에 삽입한다.

**핵심 설계: 파티션별 독립 구조체**

```cpp
// swiss_join_internal.h:630-636
struct PartitionState {
    SwissTableWithKeys keys;               // 파티션 전용 Swiss Table + key 행 배열
    RowArray payloads;                      // 파티션 전용 payload 행 배열
    std::vector<uint32_t> key_ids;         // 삽입된 행의 key id 매핑
    std::vector<uint32_t> overflow_key_ids;  // merge 시 overflow 엔트리
    std::vector<uint32_t> overflow_hashes;   // merge 시 overflow hash
};
```

각 파티션이 완전히 독립적인 `SwissTableWithKeys`를 보유하므로:
- 서로 다른 파티션을 처리하는 스레드 간에 **lock이 불필요** (lock-free)
- 각 파티션의 Swiss Table은 해당 파티션의 행 수에 비례하는 크기만 가짐 (cache에 fit할 가능성 증가)

**처리 흐름:**

```cpp
// swiss_join.cc:1220-1223
int num_rows_new =
    batch_state.prtn_ranges[prtn_id + 1] - batch_state.prtn_ranges[prtn_id];
const uint16_t* row_ids =
    batch_state.prtn_row_ids.data() + batch_state.prtn_ranges[prtn_id];
```

1. `BatchState`에서 현재 파티션에 속하는 행 범위와 row id를 가져옴
2. `SwissTableWithKeys::MapWithInserts()`로 key를 파티션 전용 Swiss Table에 삽입
3. (payload가 있는 경우) `RowArray::AppendBatchSelection()`으로 payload 행을 파티션 전용 배열에 추가

**Task 구조:**

Build phase의 task는 **파티션 단위**이다. Task id가 partition id이며, 각 task는 **모든 배치**를 순회하면서 해당 파티션의 행만 처리한다 (`swiss_join.cc:2647-2677`). 즉, 하나의 task(스레드)가 하나의 파티션을 전담한다.

### 2.3 Phase 3: Merge (파티션별 병렬 + 단일 스레드 마무리)

Build phase가 완료되면, 파티션별로 독립 구축된 Swiss Table과 행 배열을 **하나의 글로벌 구조체**로 병합한다.

#### PreparePrtnMerge (단일 스레드, `swiss_join.cc:1256-1328`)

전체 크기를 계산하고 글로벌 구조체의 메모리를 할당한다:

1. **Key rows merge 준비**: `RowArrayMerge::PrepareForMerge()`로 전체 key 행 수를 계산하고, 글로벌 `RowArray`를 할당. 각 파티션의 첫 번째 target row id를 `partition_keys_first_row_id_`에 기록
2. **Swiss Table merge 준비**: `SwissTableMerge::PrepareForMerge()`로 글로벌 Swiss Table의 block 수를 결정하고 할당. 글로벌 block 수 = (source 중 최대 block 수) * (파티션 수)
3. **Payload rows merge 준비**: (payload가 있는 경우) 동일 방식
4. **Key-to-payload 매핑 준비**: (duplicate key가 있는 경우) `row_offset_for_key_` 배열 할당

#### PrtnMerge (파티션별 병렬, `swiss_join.cc:1330-1439`)

각 파티션의 데이터를 글로벌 구조체의 해당 영역에 복사한다:

```cpp
// swiss_join.cc:1347-1356
// 1. Key rows 복사
RowArrayMerge::MergeSingle(target_->map_.keys(), *prtn_state.keys.keys(),
                           partition_keys_first_row_id_[prtn_id], nullptr);

// 2. Swiss Table entries 복사
SwissTableMerge::MergePartition(
    target_->map_.swiss_table(), prtn_state.keys.swiss_table(),
    prtn_id, log_num_prtns_, partition_keys_first_row_id_[prtn_id],
    &prtn_state.overflow_key_ids, &prtn_state.overflow_hashes);
```

**SwissTableMerge::MergePartition의 핵심 로직** (`swiss_join.cc:635-696`):

이 함수는 source Swiss Table의 모든 엔트리를 target의 해당 파티션 block 영역에 삽입한다. 이때 두 가지 핵심 변환이 수행된다:

1. **Hash 복원**: 파티셔닝 시 shift된 hash에 파티션 id 비트를 다시 삽입

```cpp
// swiss_join.cc:680-681
hash >>= num_partition_bits;
hash |= (partition_id << (SwissTable::bits_hash_ - 1 - num_partition_bits) << 1);
```

2. **Group id 조정**: 파티션-local group id에 base id를 더하여 global group id로 변환

3. **Overflow 처리**: target의 해당 파티션 block 범위를 넘어가는 엔트리는 overflow 벡터에 저장하고, 이후 단일 스레드에서 처리

이 단계에서 파티션별 block 범위가 정해져 있으므로:
```cpp
// swiss_join.cc:654-655
uint32_t target_max_block_id =
    ((partition_id + 1) << (target->log_blocks() - num_partition_bits)) - 1;
```

각 파티션은 target table에서 자신의 block 범위 내에서만 삽입을 시도하므로, 서로 다른 파티션을 병합하는 스레드 간에 **동일 block에 대한 concurrent write가 발생하지 않는다**.

#### FinishPrtnMerge (단일 스레드, `swiss_join.cc:1441-1458`)

병렬 merge에서 파티션 경계를 넘은 overflow 엔트리를 처리한다:

```cpp
// swiss_join.cc:1444-1448
for (int prtn_id = 0; prtn_id < num_prtns_; ++prtn_id) {
    SwissTableMerge::InsertNewGroups(target_->map_.swiss_table(),
                                     prtn_states_[prtn_id].overflow_key_ids,
                                     prtn_states_[prtn_id].overflow_hashes);
}
```

Overflow는 일반적으로 소수이므로 단일 스레드 처리의 비용은 낮다. 또한 null 존재 여부를 사전 계산하여 probe phase에서의 불필요한 체크를 방지한다.

---

## 3. Probe-Side Partitioning

**Acero의 probe 측은 별도의 파티셔닝을 수행하지 않는다.**

Merge phase가 완료되면 하나의 글로벌 Swiss Table이 생성되며, probe는 이 글로벌 테이블에 대해 직접 lookup을 수행한다.

`JoinProbeProcessor::OnNextBatch()`(`swiss_join.cc:2250-2416`)에서 probe 배치를 처리할 때:

1. Hash 계산: `SwissTableWithKeys::Hash()`
2. 글로벌 Swiss Table에서 직접 조회: `SwissTableWithKeys::MapReadOnly()`
3. 결과 처리: join type에 따른 분기

Probe가 파티셔닝 없이 동작할 수 있는 이유:
- Build phase에서 이미 파티션별 Swiss Table이 하나로 merge되었으므로, 모든 build 데이터가 단일 hash table에 존재
- Probe는 read-only 연산이므로 여러 스레드가 동시에 같은 hash table을 조회해도 충돌이 없음
- Probe 배치는 `task_group_probe_`를 통해 배치 단위로 병렬 처리됨

이는 DuckDB의 external join에서 probe 측도 파티셔닝(spill)하여 라운드별로 처리하는 것과 구조적으로 다르다. Acero는 spill-to-disk를 지원하지 않으므로 이러한 단순한 구조가 가능하다.

---

## 4. Swiss Table과 Partitioning의 관계

### 4.1 Hash 비트 분배의 일관성

Swiss Table과 partitioning이 hash 값의 동일한 비트 영역을 공유하는 것이 Acero 파티셔닝 설계의 핵심이다.

32비트 hash의 비트 사용 구조:

```
  [  partition bits  |  block id bits  |  stamp (7 bits)  |  하위 비트  ]
  <- log_num_prtns ->
  <----------- Swiss Table의 block_id_from_hash() ---------->
```

- **Partitioning**: 최상위 `log_num_prtns_` 비트로 파티션 결정
- **Swiss Table block id**: 최상위 `log_blocks` 비트로 block 결정
- **Swiss Table stamp**: block id 다음 7비트로 빠른 필터링

파티셔닝 후 hash를 왼쪽으로 shift하면(`hash <<= log_num_prtns_`), 파티션 내부의 Swiss Table은 원래 hash에서 파티션 비트가 제거된 hash를 사용하게 된다. 이는 파티션 내부에서 hash collision을 줄이는 효과가 있다.

### 4.2 Merge 시 자연스러운 block 매핑

파티셔닝이 hash 최상위 비트를 사용하므로, 글로벌 Swiss Table에서 각 파티션은 연속된 block 범위에 대응한다:

```
글로벌 Swiss Table (log_blocks = log_num_prtns + source_log_blocks_max):

파티션 0: block [0 .. 2^source_log_blocks_max - 1]
파티션 1: block [2^source_log_blocks_max .. 2*2^source_log_blocks_max - 1]
...
파티션 N-1: block [(N-1)*2^source_log_blocks_max .. N*2^source_log_blocks_max - 1]
```

이 덕분에 `SwissTableMerge::MergePartition()`에서 각 파티션이 자신의 block 범위 내에서만 삽입하면 되므로 병렬 merge가 가능하다. `PrepareForMerge()`(`swiss_join.cc:588-633`)에서 글로벌 테이블의 크기를 결정하는 로직이 이를 반영한다:

```cpp
// swiss_join.cc:609
int log_blocks = log_num_sources + log_blocks_max;  // 파티션 수 * 최대 source 크기
```

### 4.3 Overflow 메커니즘

Swiss Table의 linear probing 특성상, 한 block이 가득 차면 다음 block으로 overflow한다. Merge 시 이 overflow가 파티션 경계를 넘을 수 있다:

```cpp
// swiss_join.cc:689-693
bool was_inserted = InsertNewGroup(target, group_id, hash, target_max_block_id);
if (!was_inserted) {
    overflow_group_ids->push_back(group_id);
    overflow_hashes->push_back(hash);
}
```

`InsertNewGroup()`(`swiss_join.cc:698-729`)은 빈 slot을 찾아 삽입하되, `max_block_id`를 넘어서면 삽입을 포기하고 false를 반환한다. 이런 overflow 엔트리는 `FinishPrtnMerge()`에서 단일 스레드로 후처리된다.

---

## 5. Bloom Filter의 병렬 빌드와 Partitioning

Bloom filter(`BlockedBloomFilter`)의 병렬 빌드에서도 partitioning이 사용된다. 이는 hash join의 build partition과는 별개의 메커니즘이다.

### 5.1 BloomFilterBuilder_Parallel

`BloomFilterBuilder_Parallel`(`bloom_filter.h:291-320`, `bloom_filter.cc:336-428`)은 Bloom filter 비트 벡터를 여러 스레드가 동시에 갱신할 때의 race condition을 partition lock으로 해결한다.

**파티션 수 결정:**

```cpp
// bloom_filter.cc:343-344
constexpr int kMaxLogNumPrtns = 8;
log_num_prtns_ = std::min(kMaxLogNumPrtns, bit_util::Log2(num_threads));
```

- 최대 256 파티션 (`2^8`)
- 스레드 수를 초과하지 않음

**파티션 ID 계산:**

```cpp
// bloom_filter.cc:372-374
constexpr int kLogBlocksKeptTogether = 7;
constexpr int kPrtnIdBitOffset =
    BloomFilterMasks::kLogNumMasks + 6 + kLogBlocksKeptTogether;
```

Bloom filter의 block id 비트에서 상위 비트를 partition id로 사용한다. `kLogBlocksKeptTogether = 7`로 128개 block을 하나의 파티션 단위로 묶어, 같은 파티션 내의 block에 대한 접근이 하나의 lock으로 보호된다.

**처리 흐름** (`PushNextBatchImp`, `bloom_filter.cc:367-423`):

1. `PartitionSort::Eval()`로 hash들을 파티션별로 정렬
2. `PartitionLocks::AcquirePartitionLock()`으로 파티션 lock 획득 (랜덤 순서로 시도하여 contention 최소화)
3. 해당 파티션의 hash들을 `BlockedBloomFilter::Insert()`로 삽입
4. Lock 해제 후 다음 파티션 처리

### 5.2 PartitionLocks의 설계

`PartitionLocks`(`partition_util.h:93-183`, `partition_util.cc:24-87`)은 파티션별 atomic lock을 관리한다:

```cpp
// partition_util.h:175-179
struct PartitionLock {
    static constexpr int kCacheLineBytes = 64;
    std::atomic<bool> lock;
    uint8_t padding[kCacheLineBytes];  // cache line 단위 패딩으로 false sharing 방지
};
```

Lock 획득 시 `random_int()`를 사용하여 무작위 파티션부터 시도하므로, 여러 스레드가 같은 파티션에 몰리는 것을 통계적으로 방지한다. 이는 `ForEachPartition()` 템플릿 메서드에서도 동일하게 적용된다.

---

## 6. DuckDB와의 비교

| 측면 | Acero | DuckDB |
|------|-------|--------|
| **Partitioning 목적** | Build phase의 lock-free 병렬 처리 | 메모리 관리 (grace hash join) |
| **파티셔닝 대상** | Build 측만 | Build + Probe 양쪽 |
| **파티션 수 결정** | `min(DOP, rows/4096)` 동적 결정 | 초기 16개 고정, 필요시 repartition |
| **Repartitioning** | 미지원 (고정 파티션 수) | 동적 radix bits 증가 (예: 16 -> 128) |
| **Spill-to-disk** | 미지원 | 지원 (파티션 단위 spill/reload) |
| **Merge 필요 여부** | 필수 (파티션별 table -> 글로벌 table) | In-memory: `Unpartition()` / External: 파티션별 처리 |
| **Probe-side 파티셔닝** | 없음 (글로벌 table 직접 조회) | `ProbeAndSpill()`로 probe+spill 동시 수행 |
| **Hash 비트 사용** | 상위 비트 (Swiss Table과 일치) | 상위 비트 (radix partitioning) |
| **In-memory 동작** | 항상 partition + merge | 파티셔닝 무시 (`Unpartition()`) |

**핵심 차이:**
- DuckDB는 메모리 부족 시 파티션 단위로 데이터를 디스크에 spill하고, 한 번에 하나의 파티션만 메모리에 올려 처리하는 grace hash join을 구현한다. Partitioning은 이를 위한 핵심 메커니즘이다.
- Acero는 spill-to-disk를 지원하지 않으며, partitioning은 순수하게 build phase에서 lock-free 병렬 처리를 위한 작업 분할 용도이다. Build 완료 후에는 모든 파티션이 하나의 글로벌 hash table로 merge되므로, probe에서는 파티셔닝의 존재를 인지하지 않는다.
- DuckDB는 in-memory join에서 파티셔닝을 무시(`Unpartition()`)하지만, Acero는 in-memory에서도 항상 파티셔닝을 수행한다 (병렬 build를 위해). 단, 단일 스레드거나 데이터가 매우 적으면 파티션 수가 1이 되어 사실상 파티셔닝이 비활성화된다.

---

## 7. Key References

### 소스 코드 파일

| 파일 경로 | 주요 내용 |
|---|---|
| `cpp/src/arrow/acero/swiss_join.cc` | `SwissTableForJoinBuild::Init()`, `PartitionBatch()`, `ProcessPartition()`, `PreparePrtnMerge()`, `PrtnMerge()`, `FinishPrtnMerge()`, `SwissTableMerge::MergePartition()` |
| `cpp/src/arrow/acero/swiss_join_internal.h` | `SwissTableForJoinBuild`, `SwissTableMerge`, `RowArrayMerge`, `BatchState`, `PartitionState` 구조체 정의 |
| `cpp/src/arrow/acero/partition_util.h` | `PartitionSort::Eval()` (counting sort 기반 bucket sort), `PartitionLocks` (파티션별 atomic lock) |
| `cpp/src/arrow/acero/partition_util.cc` | `PartitionLocks::AcquirePartitionLock()`, `ReleasePartitionLock()`, `Init()` |
| `cpp/src/arrow/acero/bloom_filter.h` | `BloomFilterBuilder_Parallel`, `BlockedBloomFilter` |
| `cpp/src/arrow/acero/bloom_filter.cc` | `BloomFilterBuilder_Parallel::PushNextBatchImp()` (파티션 기반 병렬 Bloom filter 빌드) |
| `cpp/src/arrow/compute/key_map_internal.h` | `SwissTable::block_id_from_hash()`, `bits_hash_`, block/slot/stamp 구조 |
| `cpp/src/arrow/acero/hash_join_node.cc` | `BloomFilterPushdownContext`, `FilterSingleBatch()` |

### 주요 함수

| 함수명 | 파일 | 역할 |
|---|---|---|
| `SwissTableForJoinBuild::Init()` | `swiss_join.cc:1102` | 파티션 수 결정 및 초기화 |
| `SwissTableForJoinBuild::PartitionBatch()` | `swiss_join.cc:1156` | 배치를 hash 기반으로 파티션 분류 |
| `PartitionSort::Eval()` | `partition_util.h:66` | O(n) counting sort 기반 파티션 정렬 |
| `SwissTableForJoinBuild::ProcessPartition()` | `swiss_join.cc:1210` | 파티션별 Swiss Table에 키 삽입 |
| `SwissTableForJoinBuild::PreparePrtnMerge()` | `swiss_join.cc:1256` | 글로벌 구조체 메모리 할당 |
| `SwissTableForJoinBuild::PrtnMerge()` | `swiss_join.cc:1330` | 파티션 데이터를 글로벌 구조체에 복사 |
| `SwissTableMerge::MergePartition()` | `swiss_join.cc:635` | 파티션 Swiss Table 엔트리를 글로벌 테이블에 삽입 |
| `SwissTableMerge::PrepareForMerge()` | `swiss_join.cc:588` | 글로벌 Swiss Table 크기 결정 및 할당 |
| `SwissTableForJoinBuild::FinishPrtnMerge()` | `swiss_join.cc:1441` | Overflow 엔트리 후처리 |
| `BloomFilterBuilder_Parallel::PushNextBatchImp()` | `bloom_filter.cc:367` | 파티션 lock 기반 병렬 Bloom filter 빌드 |
| `PartitionLocks::AcquirePartitionLock()` | `partition_util.cc:56` | 랜덤 순서 파티션 lock 획득 |

### 참고 자료

- Apache Arrow 소스 코드: https://github.com/apache/arrow (본 분석은 해당 저장소의 소스 코드 기반)
- Abseil Swiss Table: https://abseil.io/about/design/swisstables (Arrow Swiss Table의 영감 원본)
