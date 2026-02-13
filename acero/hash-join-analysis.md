# Apache Arrow Acero — Hash Join 구현 분석

## 1. Hash Table 구조: Swiss Table

Acero의 Hash Join은 **Swiss Table** 기반의 hash table을 사용한다. 이는 Google Abseil의 Swiss Table에서 영감을 받은 구조로, `arrow::compute::SwissTable` 클래스에 구현되어 있다 (`cpp/src/arrow/compute/key_map_internal.h`).

### Block 기반 구조

Swiss Table은 **block 단위**로 구성된다. 각 block은 8개의 slot을 가지며 (`kSlotsPerBlock = 8`), 다음과 같은 레이아웃을 갖는다:

- **Status bytes (8바이트)**: 각 slot당 1바이트. 이 중 **7비트는 stamp** (hash의 상위 비트 일부)로 사용되고, 최상위 비트(MSB)는 slot이 비어있는지 표시한다 (`key_map_internal.h:277-282`).
- **Group ID 영역**: slot별 group id가 bit-packed 형태로 저장된다. Group id의 비트 수는 `log_blocks + kLogSlotsPerBlock`로 결정되며, 8/16/32비트 중 하나로 정렬된다 (`num_groupid_bits_from_log_blocks()`, `key_map_internal.h:116-121`).

### Hash 사용 방식

32비트 hash (`bits_hash_ = 32`)를 다음과 같이 분할하여 사용한다:
- **최상위 비트**: block id 결정 (`block_id_from_hash()`, `key_map_internal.h:108-110`)
- **다음 7비트**: stamp — 빠른 필터링에 사용 (`bits_stamp_ = 7`, `key_map_internal.h:282`)
- **하위 비트**: mask id 등 추가 식별에 사용

### Early Filter 메커니즘

`early_filter()` 메서드 (`key_map_internal.h:60-61`)는 stamp 비교를 통해 hash table에 존재하지 않는 키를 빠르게 걸러낸다. 8바이트 block의 status bytes를 한 번에 로드하여 stamp 매칭을 수행하며, 매칭되지 않으면 비교 없이 즉시 제외한다. AVX2가 사용 가능한 경우 SIMD 가속 버전을 활용한다 (`early_filter_imp_avx2_x8`, `early_filter_imp_avx2_x32`, `key_map_internal.h:223-227`).

### 두 가지 구현체 선택

`HashJoinNode::Make()` (`hash_join_node.cc:766-777`)에서 Swiss Join과 Basic(legacy) Join 중 하나를 선택한다:
- **SwissJoin**: dictionary 타입과 large binary가 없는 경우, little-endian 시스템에서 사용
- **BasicJoin**: dictionary 타입이나 large binary가 포함된 경우 fallback

```cpp
// hash_join_node.cc:766-777
use_swiss_join = !schema_mgr->HasDictionaries() && !schema_mgr->HasLargeBinary();
if (use_swiss_join) {
    impl = HashJoinImpl::MakeSwiss();
} else {
    impl = HashJoinImpl::MakeBasic();
}
```

## 2. Build Phase

Build phase는 3단계 파이프라인으로 구성되며, 각 단계가 task group으로 등록되어 병렬 실행된다.

### 2.1 Phase 1: Partition (병렬)

`SwissTableForJoinBuild::PartitionBatch()` (`swiss_join.cc:1156-1208`)에서 각 배치를 hash 기반으로 partition한다.

1. **Hash 계산**: `Hashing32::HashBatch()`로 각 row의 32비트 hash를 계산
2. **Partition 분배**: hash의 최상위 `log_num_prtns_` 비트로 partition을 결정하여 row를 분류 (`PartitionSort::Eval()`)
3. **Hash 조정**: partition에 사용된 상위 비트를 제거하기 위해 hash를 왼쪽으로 shift

Partition 수는 `min(log2(dop), log2(num_rows / min_num_rows_per_prtn))`로 결정되며, `min_num_rows_per_prtn = 4096`이다 (`swiss_join.cc:1114-1118`).

### 2.2 Phase 2: Build Per-Partition (병렬)

`SwissTableForJoinBuild::ProcessPartition()` (`swiss_join.cc:1210-1254`)에서 각 partition별로 독립적인 Swiss Table에 키를 삽입한다.

- 각 partition은 독립적인 `SwissTableWithKeys`를 가지므로 lock-free로 병렬 처리 가능
- `SwissTableWithKeys::MapWithInserts()`를 통해 키를 삽입하거나 기존 키의 group id를 매핑
- Payload 행도 partition별 `RowArray`에 추가

### 2.3 Phase 3: Merge (병렬 + 단일 스레드 마무리)

Partition별 Swiss Table과 Row Array를 하나의 global 구조체로 병합한다.

**PreparePrtnMerge** (`swiss_join.cc:1256-1328`, 단일 스레드):
- 전체 key/payload row 수와 크기를 계산하여 대상 메모리 할당
- `RowArrayMerge::PrepareForMerge()` 및 `SwissTableMerge::PrepareForMerge()` 호출

**PrtnMerge** (`swiss_join.cc:1330-1439`, partition별 병렬):
- `RowArrayMerge::MergeSingle()`: key row와 payload row를 대상 배열에 복사
- `SwissTableMerge::MergePartition()`: Swiss Table 엔트리를 대상 테이블에 삽입. Partition 경계를 넘는 overflow 엔트리는 별도 저장

**FinishPrtnMerge** (`swiss_join.cc:1441-1458`, 단일 스레드):
- Overflow 엔트리를 `SwissTableMerge::InsertNewGroups()`로 처리
- Null 존재 여부를 사전 계산

### Row-Oriented Key Encoding

키는 `RowTableEncoder` (`arrow/compute/row/row_encoder_internal.h`)를 통해 row-oriented 바이너리 포맷으로 인코딩된다. 고정 길이 컬럼은 64비트 정렬, 가변 길이 컬럼은 offset 기반으로 저장된다 (`RowArray::InitIfNeeded()`, `swiss_join.cc:61-86`). 이 인코딩은 키 비교 시 `KeyCompare::CompareColumnsToRows()`로 효율적 비교를 가능하게 한다.

## 3. Probe Phase

### 3.1 기본 Probe 흐름

`JoinProbeProcessor::OnNextBatch()` (`swiss_join.cc:2250-2416`)에서 probe 측 배치를 처리한다:

1. **Hash 계산**: `SwissTableWithKeys::Hash()`로 키의 hash 계산
2. **Hash Table Lookup**: `SwissTableWithKeys::MapReadOnly()` (`swiss_join.cc:945-948`)로 hash table에서 매칭. 내부적으로 `swiss_table_.early_filter()` → `swiss_table_.find()` 순서로 실행
3. **Null 필터링**: `JoinNullFilter::Filter()`로 EQ 비교에서 null 키 행을 제거
4. **Join Type별 처리**: join 타입에 따라 semi/anti/inner/outer 각각의 경로로 분기
5. **Result Materialization**: `JoinResultMaterialize`를 통해 probe/build 양쪽 데이터를 결합하여 출력 배치 생성

### 3.2 Mini-batch 처리

Probe는 `swiss_table_.minibatch_size()`(일반적으로 수백 행) 단위의 mini-batch로 분할 처리된다 (`swiss_join.cc:2283-2412`). 이는 임시 버퍼의 스택 할당을 가능하게 하고, CPU cache 효율성을 높인다.

### 3.3 Bloom Filter를 통한 사전 필터링

`BloomFilterPushdownContext` (`hash_join_node.cc:505-677`)가 Bloom filter 기반 사전 필터링을 담당한다.

**Build 측**:
- Build 측 배치가 모두 축적되면 `BuildBloomFilter()`가 호출
- `BlockedBloomFilter` (`bloom_filter.h:106-240`)는 64비트 block 단위의 Bloom filter로, 각 block은 57비트 마스크 (`BloomFilterMasks::kBitsPerMask = 57`) 기반으로 동작
- 마스크는 4~5비트가 설정되어 낮은 false positive rate를 달성 (`kMinBitsSet = 4, kMaxBitsSet = 5`)
- `Fold()` 메서드로 비트 밀도가 낮은 경우 필터를 절반으로 축소 가능 (`bloom_filter.cc:221-261`)

**Probe 측**:
- `FilterSingleBatch()` (`hash_join_node.cc:565-619`)에서 probe 배치의 키를 hash하여 Bloom filter 조회
- 매칭되지 않는 행을 선별적으로 필터링하여 hash table lookup 비용 절감
- 여러 upstream join에서 전파된 Bloom filter를 AND 연산으로 결합

**Pushdown 전략**:
- `GetPushdownTarget()` (`hash_join_node.cc:1176-1278`)에서 Bloom filter를 하위 join 노드로 전파할 대상을 결정
- Left Anti, Left Outer, Full Outer join에는 Bloom filter가 적용되지 않음 (false negative 없이 early elimination만 가능하므로)

## 4. Partitioning 전략

Acero는 **radix partitioning** 전략을 사용하여 cache 효율성과 병렬성을 동시에 달성한다.

### Partition 결정

`SwissTableForJoinBuild::Init()` (`swiss_join.cc:1102-1154`)에서:
```cpp
constexpr int64_t min_num_rows_per_prtn = 1 << 12;  // 4096
log_num_prtns_ = std::min(
    bit_util::Log2(dop_),
    bit_util::Log2(bit_util::CeilDiv(num_rows, min_num_rows_per_prtn)));
num_prtns_ = 1 << log_num_prtns_;
```

- Partition 수는 항상 2의 거듭제곱
- DOP (Degree of Parallelism, 스레드 수)와 데이터 크기를 모두 고려
- Hash의 최상위 비트로 partition을 결정 — Swiss Table의 block id 결정 방식과 일치하여 merge 시 자연스러운 매핑

### Partition Sort

`PartitionSort::Eval()` (`swiss_join.cc:1186-1197`)로 배치 내 행을 partition별로 정렬. 이는 후속 build 단계에서 각 partition에 대한 sequential access를 가능하게 한다.

## 5. Parallelism (병렬 처리)

### 5.1 Task-Based 병렬 모델

Acero는 **task group** 기반의 병렬 모델을 사용한다. `QueryContext::RegisterTaskGroup()` / `StartTaskGroup()`을 통해 task를 등록하고 실행한다.

`SwissJoin::InitTaskGroups()` (`swiss_join.cc:2487-2514`)에서 다음 6개의 task group을 등록한다:

| Task Group | 함수 | 병렬 단위 | 설명 |
|---|---|---|---|
| `task_group_partition_` | `PartitionTask` | batch 수 | Build 배치를 hash 기반 partition |
| `task_group_build_` | `BuildTask` | partition 수 | Partition별 Swiss Table 빌드 |
| `task_group_merge_` | `MergeTask` | partition 수 | Partition별 hash table merge |
| `task_group_scan_` | `ScanTask` | hash table row / N | Right outer/semi/anti를 위한 hash table 스캔 |
| `task_group_flush_` | `FlushTask` | 스레드 수 | 스레드별 materialize 버퍼 flush |
| `task_group_probe_` | (HashJoinNode) | 배치 수 | Probe 측 queued 배치 처리 |

### 5.2 Build Phase 병렬화

Build는 3단계 파이프라인:

1. **Partition Phase** (`PartitionTask`, `swiss_join.cc:2598-2620`): 각 build 배치를 독립적으로 hash+partition. `build_side_batches_.batch_count()`개의 task 병렬 실행.

2. **Build Phase** (`BuildTask`, `swiss_join.cc:2630-2679`): 각 partition에 대해 모든 배치의 해당 partition 행을 처리. `num_prtns_`개의 task 병렬 실행. 각 partition은 독립적인 `SwissTableWithKeys`를 가지므로 **lock-free** 병렬 처리.

3. **Merge Phase** (`MergeTask`, `swiss_join.cc:2696-2703`): partition별 Swiss Table을 global table로 merge. `num_prtns_`개의 task 병렬 실행. Partition 경계를 넘는 overflow는 `FinishPrtnMerge()`에서 단일 스레드로 처리.

### 5.3 Probe Phase 병렬화

- `HashJoinNode::OnProbeSideBatch()` (`hash_join_node.cc:823-841`)에서 probe 배치가 도착하면:
  - Bloom filter가 준비되지 않았으면 `probe_accumulator_`에 queue
  - Hash table이 준비되지 않았으면 역시 queue
  - 둘 다 준비되면 즉시 `impl_->ProbeSingleBatch()` 호출
- Queue된 배치는 `ProbeQueuedBatches()` (`hash_join_node.cc:881-888`)에서 `task_group_probe_`를 통해 배치별 병렬 처리

### 5.4 Thread-Local State

각 스레드는 독립적인 로컬 상태를 유지한다 (`SwissJoin` 내 `local_states_`):

```cpp
// swiss_join.cc 내 SwissJoin 클래스
struct ThreadLocalState {
    arrow::util::TempVectorStack stack;  // 임시 버퍼 스택
    std::vector<KeyColumnArray> temp_column_arrays;
    int num_output_batches;
    JoinResultMaterialize materialize;  // 스레드별 결과 materialization
};
```

- `TempVectorStack`: mini-batch 처리를 위한 스택 기반 임시 메모리 할당
- `JoinResultMaterialize`: 스레드별 독립적인 결과 누적 — 결과 생성에 lock 불필요

### 5.5 Has-Match 비트벡터 병렬 처리

Right outer/full outer join에서는 build 측의 어떤 행이 매칭되었는지 추적해야 한다. `SwissTableForJoin`은 **thread-local has_match 비트벡터** (`swiss_join_internal.h:502-504`)를 사용하며, probe 완료 후 `MergeHasMatch()` (`swiss_join.cc:1071-1086`)에서 `BitmapOr`로 병합한다.

### 5.6 Bloom Filter 병렬 빌드

`BloomFilterBuilder_Parallel` (`bloom_filter.h:291-320`)은 Bloom filter를 병렬로 빌드:
- 각 스레드가 hash를 partition하고 (`partitioned_hashes_32`)
- Partition별 lock (`PartitionLocks`)을 사용하여 동일 partition에 대한 concurrent insert 방지

### 5.7 동기화 메커니즘

- **Build/Probe 상태 관리**: `probe_side_mutex_`를 통해 `bloom_filters_ready_`, `hash_table_ready_`, `queued_batches_filtered_` 등의 상태를 원자적으로 관리 (`hash_join_node.cc:1049-1055`)
- **Build 측 축적**: `build_side_mutex_`로 build 배치 축적 보호 (`hash_join_node.cc:1049`)
- **AtomicCounter**: `batch_count_[2]`로 양측의 배치 완료를 atomic하게 추적 (`hash_join_node.cc:1038`)

## 6. Memory Management

### Memory Pool

모든 메모리 할당은 Arrow의 `MemoryPool`을 통해 이루어진다:
- Swiss Table block 배열, hash 배열
- `RowArray`의 행 데이터 (`RowTableImpl` 내부)
- Bloom filter의 block 배열 (`BlockedBloomFilter::CreateEmpty()`, `bloom_filter.cc:97-117`)
- Bloom filter 크기: `max(512, num_rows * 8)` 비트 기준으로 할당 (`bloom_filter.cc:100-103`)

### Bloom Filter 메모리 최적화

- **Fold 메커니즘** (`bloom_filter.cc:221-261`): duplicate 키가 많아 비트 밀도가 낮은 경우 (< 1/4), 필터를 반복적으로 절반으로 축소하여 메모리와 cache 효율 개선
- **Prefetch**: 큰 Bloom filter (> 256KB)의 경우 메모리 prefetch 사용 (`bloom_filter.h:220-224`)

### TempVectorStack

Mini-batch 처리를 위한 임시 메모리는 `TempVectorStack`으로 스택 기반 할당:
- 스레드별 고정 크기 스택 (SwissJoin: `64 * MiniBatch::kMiniBatchLength` 바이트)
- Heap 할당 오버헤드 없이 빠른 할당/해제

### Spill-to-Disk

Acero의 Hash Join은 현재 **spill-to-disk를 지원하지 않는다**. 모든 build 측 데이터가 메모리에 상주해야 한다. 이는 DuckDB 등의 엔진과 대비되는 제한점이다.

## 7. Join Types 지원

`HashJoinNode`은 다음 join 타입을 지원한다 (`hash_join_node.cc:125-140`, `swiss_join.cc:2300-2410`):

| Join Type | 구현 세부 | 특이사항 |
|---|---|---|
| **INNER** | `JoinMatchIterator` + `JoinResultMaterialize::Append()` | 매칭 쌍을 열거하여 결과 생성 |
| **LEFT_OUTER** | Inner 처리 후 비매칭 probe 행에 null 패딩 | `AppendProbeOnly()` for non-matches |
| **RIGHT_OUTER** | Inner 처리 + has_match 추적 → scan phase에서 비매칭 build 행 출력 | Thread-local has_match 비트벡터 사용 |
| **FULL_OUTER** | LEFT_OUTER + RIGHT_OUTER 결합 | 가장 비용이 큰 join 타입 |
| **LEFT_SEMI** | `JoinResidualFilter::FilterLeftSemi()` | 매칭 존재 여부만 확인, duplicate key 무시 가능 |
| **LEFT_ANTI** | `JoinResidualFilter::FilterLeftAnti()` | Left Semi의 역 — 비매칭 행 출력 |
| **RIGHT_SEMI** | `JoinResidualFilter::FilterRightSemiAnti()` + scan phase | has_match bit가 설정된 build 행 출력 |
| **RIGHT_ANTI** | `JoinResidualFilter::FilterRightSemiAnti()` + scan phase | has_match bit가 미설정된 build 행 출력 |

### Semi/Anti Join 최적화

Left semi/anti join에서는 `reject_duplicate_keys_ = true`로 설정되어 동일 키의 중복 삽입을 방지하고, payload 처리를 완전히 생략한다 (`swiss_join.cc:2565-2570`).

### Residual Filter

`JoinResidualFilter` (`swiss_join.cc:1842-2230`)는 join 키 매칭 이후 추가적인 filter expression을 평가한다:
- Trivial filter (literal true/false)의 경우 zero-cost shortcut 제공
- Non-trivial filter의 경우 probe/build 양쪽 컬럼을 `MaterializeFilterInput()`으로 구체화한 후 `ExecuteScalarExpression()`으로 평가

### Scan Phase

Right semi/anti/outer, full outer join에서는 probe 완료 후 hash table을 스캔하여 비매칭 build 행을 처리한다:
- `StartScanHashTable()` → `MergeHasMatch()` → `ScanTask()` (`swiss_join.cc:2732-2838`)
- `kNumRowsPerScanTask` 단위로 병렬 스캔

## 8. Key References

### 소스 코드 파일

| 파일 경로 | 주요 내용 |
|---|---|
| `cpp/src/arrow/acero/hash_join_node.cc` | `HashJoinNode`, `BloomFilterPushdownContext` |
| `cpp/src/arrow/acero/hash_join_node.h` | `HashJoinSchema` |
| `cpp/src/arrow/acero/hash_join.h` | `HashJoinImpl` 인터페이스 (MakeSwiss/MakeBasic) |
| `cpp/src/arrow/acero/swiss_join.cc` | `SwissJoin`, `SwissTableForJoinBuild`, `JoinProbeProcessor`, `JoinResultMaterialize`, `JoinResidualFilter`, `JoinMatchIterator` |
| `cpp/src/arrow/acero/swiss_join_internal.h` | `RowArray`, `SwissTableWithKeys`, `SwissTableForJoin`, `SwissTableForJoinBuild`, `SwissTableMerge`, `RowArrayMerge` |
| `cpp/src/arrow/acero/bloom_filter.h` | `BlockedBloomFilter`, `BloomFilterBuilder` |
| `cpp/src/arrow/acero/bloom_filter.cc` | Bloom filter 구현 (insert, find, fold) |
| `cpp/src/arrow/compute/key_map_internal.h` | `SwissTable` 핵심 구현 (block, slot, stamp, early_filter, find) |

### 주요 함수

| 함수명 | 파일 | 역할 |
|---|---|---|
| `SwissTable::early_filter()` | `key_map_internal.h` | Stamp 기반 빠른 필터링 |
| `SwissTable::find()` | `key_map_internal.h` | Hash table 키 조회 |
| `SwissTableForJoinBuild::PartitionBatch()` | `swiss_join.cc:1156` | Build 배치 partition |
| `SwissTableForJoinBuild::ProcessPartition()` | `swiss_join.cc:1210` | Partition별 키 삽입 |
| `SwissTableMerge::MergePartition()` | `swiss_join.cc:635` | Partition Swiss Table merge |
| `JoinProbeProcessor::OnNextBatch()` | `swiss_join.cc:2250` | Probe 배치 처리 메인 루프 |
| `BloomFilterPushdownContext::BuildBloomFilter()` | `hash_join_node.cc:1115` | Bloom filter 빌드 |
| `BlockedBloomFilter::Find()` | `bloom_filter.h:113` | Bloom filter 조회 |
| `HashJoinNode::Make()` | `hash_join_node.cc:725` | Join 노드 생성 및 Swiss/Basic 선택 |
| `SwissJoin::InitTaskGroups()` | `swiss_join.cc:2487` | 6개 task group 등록 |

### 참고 자료

- Apache Arrow 소스 코드: https://github.com/apache/arrow (본 분석은 해당 저장소의 소스 코드 기반)
- "Recent Improvements to Hash Join in Arrow C++" — Arrow 블로그 (2025), Swiss Table 도입과 병렬 빌드 개선 관련
- Abseil Swiss Table: https://abseil.io/about/design/swisstables — Arrow의 Swiss Table이 영감을 받은 원본 구현
