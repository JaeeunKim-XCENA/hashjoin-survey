# Apache DataFusion — Hash Join 구현 분석

## 1. Hash Table 구조

DataFusion의 hash join은 두 가지 종류의 map 구조를 사용한다 (`joins/mod.rs:53`, `Map` enum):

### 1.1 JoinHashMap (기본 해시 맵)

`JoinHashMapType` trait (`joins/join_hash_map.rs:105`)을 구현하는 두 가지 변형이 있다:

- **`JoinHashMapU32`** (`join_hash_map.rs:139`): build side 행 수가 `u32::MAX` 이하일 때 사용. 내부적으로 `hashbrown::HashTable<(u64, u32)>`를 사용한다.
- **`JoinHashMapU64`** (`join_hash_map.rs:217`): build side 행 수가 `u32::MAX`를 초과할 때 사용. `hashbrown::HashTable<(u64, u64)>`를 사용한다.

두 구조 모두 **chained list** 방식으로 같은 hash 값을 가진 복수의 행 인덱스를 관리한다. hash table의 각 항목은 `(hash_value, last_row_index+1)` 쌍을 저장하고, 별도의 `next: Vec<T>` 배열에서 linked list를 구성한다. 이 설계는 Boncz et al.의 논문 "Balancing vectorized query execution with bandwidth-optimized storage" (Chapter 5.3)에서 영감을 받은 것이다 (`join_hash_map.rs:46`).

체인 구조 예시 (코드 주석에서 발췌):
```
Insert (10,1) → map: {10: 2}, next: [0,0,0,0,0]
Insert (10,3) → map: {10: 4}, next: [0,0,0,2,0]  // hash 10 → 4→2 (indices 3,1)
Insert (10,4) → map: {10: 5}, next: [0,0,0,2,4]  // hash 10 → 5→4→2 (indices 4,3,1)
```

`next[i]` 값이 0이면 chain의 끝을 의미한다. 실제 인덱스는 1-based로 저장되어 0을 sentinel로 사용할 수 있다.

### 1.2 ArrayMap (Perfect Hash Join)

단일 정수형 join key에 대해 직접 배열 인덱싱을 사용하는 dense map이다 (`joins/array_map.rs:56`). `data[val - min_val] → row_index + 1` 형태로 매핑한다. 다음 조건을 모두 만족할 때만 사용된다 (`hash_join/exec.rs:447-457`):

1. Join key가 정확히 1개
2. 64비트 이하 정수형 (i128/u128 미지원)
3. Key 범위가 충분히 작거나 (`perfect_hash_join_small_build_threshold`), key density가 높거나 (`perfect_hash_join_min_key_density`)
4. `build_side.num_rows() < u32::MAX`
5. NullEqualsNothing이거나 (NullEqualsNull이고 build side에 null이 없는 경우)

`try_create_array_map()` 함수 (`exec.rs:102`)에서 이 조건을 검사하고 ArrayMap 생성을 시도한다.

## 2. Build Phase

Build phase는 `collect_left_input()` 함수 (`exec.rs:1713`)에서 비동기적으로 수행된다.

### 2.1 데이터 수집

1. Build side의 `SendableRecordBatchStream`에서 모든 batch를 `try_fold`로 소비하며 메모리에 적재한다 (`exec.rs:1739-1762`).
2. 각 batch 수집 시 `MemoryReservation.try_grow()`로 메모리 예약을 수행하고, 실패 시 에러를 반환한다.
3. Dynamic filter pushdown이 활성화된 경우, `CollectLeftAccumulator`를 통해 각 join key 컬럼의 min/max bounds를 누적 계산한다 (`exec.rs:1565-1633`).

### 2.2 Hash Table 빌드

데이터 수집 완료 후:

1. **ArrayMap 우선 시도**: `try_create_array_map()`으로 perfect hash join 가능 여부를 판단하고, 가능하면 ArrayMap을 생성한다.
2. **JoinHashMap 빌드**: ArrayMap이 불가능한 경우, 행 수에 따라 `JoinHashMapU32` 또는 `JoinHashMapU64`를 생성한다 (`exec.rs:1809-1821`).

Hash table 빌드 시 **batch를 역순으로 순회**한다 (`exec.rs:1826-1843`). 이는 LIFO 구조의 hash table에서 원래 입력 순서를 보존하기 위함이다. 마지막 batch부터 offset 0으로 시작하여, 작은 인덱스의 행이 chain 상단에 위치하게 된다 (`exec.rs:510-543` 주석 참조).

`update_hash()` → `update_from_iter()` (`join_hash_map.rs:298`) 호출 체인을 통해 각 행의 hash 값을 계산하고 hash table에 삽입한다. 모든 batch는 `concat_batches()`로 하나의 큰 RecordBatch로 합쳐진다 (`exec.rs:1846`).

### 2.3 Build 결과

`JoinLeftData` 구조체 (`exec.rs:185`)가 build 결과를 캡슐화한다:
- `map: Arc<Map>` — hash table (HashMap 또는 ArrayMap)
- `batch: RecordBatch` — 합쳐진 build side 데이터
- `values: Vec<ArrayRef>` — build side join key 컬럼 값들
- `visited_indices_bitmap: SharedBitmapBuilder` — outer join을 위한 방문 비트맵
- `probe_threads_counter: AtomicUsize` — probe 완료 카운터
- `bounds: Option<PartitionBounds>` — dynamic filter용 min/max bounds

## 3. Probe Phase

Probe phase는 `HashJoinStream`의 state machine으로 구현된다 (`hash_join/stream.rs:182`).

### 3.1 State Machine

상태 전이는 다음과 같다 (`stream.rs:114-123`):

```
WaitBuildSide → [WaitPartitionBoundsReport →] FetchProbeBatch ⟷ ProcessProbeBatch → ExhaustedProbeSide → Completed
```

1. **WaitBuildSide**: `collect_build_side()` (`stream.rs:479`)에서 build future를 poll하여 hash table 완성을 기다린다.
2. **WaitPartitionBoundsReport**: (선택적) dynamic filter가 모든 partition에서 보고될 때까지 대기.
3. **FetchProbeBatch**: `fetch_probe_batch()` (`stream.rs:554`)에서 probe side에서 batch를 하나 가져와 hash 값을 사전 계산한다.
4. **ProcessProbeBatch**: `process_probe_batch()` (`stream.rs:596`)에서 실제 join 매칭을 수행한다.
5. **ExhaustedProbeSide**: `process_unmatched_build_batch()` (`stream.rs:813`)에서 outer/anti join의 미매칭 행을 출력한다.

### 3.2 Probe 매칭 로직

`lookup_join_hashmap()` 함수 (`stream.rs:286`)가 핵심 매칭을 수행한다:

1. `get_matched_indices_with_limit_offset()`로 hash 값 기반 후보 인덱스 쌍을 추출 (batch_size 제한 적용)
2. `equal_rows_arr()`로 hash collision 검증 — 실제 key 값 비교로 정확한 매칭만 남김
3. 결과는 `(build_indices: UInt64Array, probe_indices: UInt32Array)` 형태

**Limit/Offset 기반 분할 처리**: 하나의 probe batch에서 join 결과가 `batch_size`를 초과할 수 있으므로, `MapOffset` (`(usize, Option<u64>)`)으로 다음 처리 위치를 추적하여 여러 번에 걸쳐 출력한다 (`join_hash_map.rs:379`).

매칭 후 `adjust_indices_by_join_type()`으로 join type에 따른 인덱스 조정과 `apply_join_filter_to_indices()`로 filter 적용을 거쳐 `build_batch_from_indices()`로 최종 RecordBatch를 생성한다.

### 3.3 Output Coalescing

`LimitedBatchCoalescer`를 사용하여 작은 출력 batch들을 `batch_size` 크기로 병합하고, `fetch` limit이 설정된 경우 조기 종료를 지원한다 (`stream.rs:226`, `stream.rs:380`).

## 4. Partitioning 전략

DataFusion은 `PartitionMode` enum (`joins/mod.rs:85`)으로 세 가지 전략을 제공한다:

### 4.1 CollectLeft

- Build side를 단일 partition으로 수집하여 하나의 hash table을 생성한다.
- `OnceAsync<JoinLeftData>` (`exec.rs:643`)를 통해 모든 probe partition이 **동일한 hash table을 공유**한다.
- `Distribution::SinglePartition` 요구: build side 앞에 `CoalescePartitionsExec`가 삽입된다.
- Probe side는 원래 partitioning을 유지한다.
- **Build side가 작을 때 적합**: hash table 복제 비용 없이 probe side의 parallelism을 활용할 수 있다.

### 4.2 Partitioned

- Build side와 probe side를 **동일한 hash partitioning**으로 repartition한다 (`exec.rs:1095-1105`).
- 각 partition이 독립적으로 build → probe를 수행한다.
- `Distribution::HashPartitioned(left_expr)` / `Distribution::HashPartitioned(right_expr)` 요구.
- 앞에 `RepartitionExec`가 삽입되어 join key 기반 hash partitioning을 보장한다.
- **양쪽 테이블이 모두 클 때 적합**: 각 partition의 hash table이 작아져 메모리 효율적이다.

### 4.3 Auto

- 옵티마이저가 통계 기반으로 CollectLeft 또는 Partitioned를 자동 선택한다 (`exec.rs:1106-1109`).
- 실행 시점에는 Auto가 존재하면 안 된다 — `execute()` 시 에러 반환 (`exec.rs:1287`).

### 4.4 Repartitioning 세부사항

`HASH_JOIN_SEED` (`exec.rs:96`)는 `('J', 'O', 'I', 'N')` 시드를 사용하여 `RepartitionExec`의 `(0, 0, 0, 0)` 시드와 다른 hash 값을 생성함으로써 hash collision을 방지한다.

## 5. Parallelism (**핵심 섹션**)

DataFusion의 hash join parallelism은 **Tokio 기반 비동기 실행 모델** 위에 구축된다.

### 5.1 실행 모델 개요

DataFusion은 Volcano-style pull 모델을 async/await로 구현한다. 각 `ExecutionPlan::execute(partition)` 호출은 `SendableRecordBatchStream`을 반환하고, 이 stream들은 Tokio runtime에서 concurrent하게 poll된다.

### 5.2 CollectLeft 모드의 Parallelism

```
┌─────────────┐
│ Build Side  │ ──(single partition)──► collect_left_input() ──► OnceAsync<JoinLeftData>
└─────────────┘                                                       │
                                                          ┌───────────┼───────────┐
                                                          ▼           ▼           ▼
                                                    Probe Partition 0  Part 1  ... Part N
                                                    (HashJoinStream)  (각각 독립 stream)
```

- **Build**: `OnceAsync` (`utils.rs:349`)가 build 작업을 정확히 한 번만 실행하고, 결과를 `Shared<BoxFuture>` (`OnceFut`)로 모든 probe stream에 공유한다 (`exec.rs:1245`). 첫 번째 `try_once()` 호출만 실제 future를 생성하고, 이후 호출은 같은 future의 clone을 반환한다.
- **Probe**: 각 output partition에 대해 독립적인 `HashJoinStream`이 생성된다 (`exec.rs:1342`). 모든 stream이 동일한 `Arc<JoinLeftData>`를 참조하여 **hash table을 공유**한다.
- **Thread-safety**: `JoinLeftData`의 `visited_indices_bitmap`은 `parking_lot::Mutex<BooleanBufferBuilder>`로 보호되고 (`exec.rs:194`), `probe_threads_counter`는 `AtomicUsize`로 관리된다 (`exec.rs:197`).

### 5.3 Partitioned 모드의 Parallelism

```
Build Part 0 ──► collect_left_input() ──► JoinLeftData 0 ──► HashJoinStream(partition=0)
Build Part 1 ──► collect_left_input() ──► JoinLeftData 1 ──► HashJoinStream(partition=1)
  ...                                                           ...
Build Part N ──► collect_left_input() ──► JoinLeftData N ──► HashJoinStream(partition=N)
```

- 각 partition이 **독립적으로** build와 probe를 수행한다.
- `self.left.execute(partition)` / `self.right.execute(partition)` (`exec.rs:1266, 1325`)으로 같은 partition 번호의 stream을 가져온다.
- `OnceFut::new()` 사용 — `OnceAsync`가 아닌 단독 future (`exec.rs:1272`).
- Build side 간에 공유 상태가 없으므로 lock contention이 없다.

### 5.4 Outer Join에서의 Cross-Partition 동기화

Left/Full outer join 등에서 미매칭 build side 행을 출력해야 하는 경우:

- **CollectLeft**: 모든 probe partition이 같은 `visited_indices_bitmap`을 Mutex로 공유 갱신한다.
- `probe_threads_counter` (`AtomicUsize`)로 마지막 probe stream을 추적한다 (`exec.rs:244-247`).
- `report_probe_completed()` (`exec.rs:245`)가 `fetch_sub(1, Ordering::Relaxed)`를 수행하여 반환값이 1이면 마지막 thread임을 알 수 있다.
- 마지막 thread만이 `get_final_indices_from_shared_bitmap()`을 호출하여 미매칭 행을 출력한다 (`stream.rs:837-847`).

### 5.5 Dynamic Filter Pushdown과 Partition 간 동기화

`SharedBuildAccumulator` (`shared_bounds.rs:216`)가 partition 간 dynamic filter 정보를 조율한다:

- `tokio::sync::Barrier`를 사용하여 모든 partition의 build 완료를 동기화한다 (`shared_bounds.rs:219`).
- 각 partition이 `report_build_data()`를 호출하면, 마지막 partition이 도착했을 때 전체 bounds를 merge하여 `DynamicFilterPhysicalExpr`을 갱신한다.
- Probe stream은 `WaitPartitionBoundsReport` 상태 (`stream.rs:129`)에서 filter 갱신 완료를 대기한 후 probe를 시작한다.

### 5.6 Null-Aware Anti Join의 Cross-Partition 동기화

`probe_side_non_empty`와 `probe_side_has_null` (`exec.rs:211-214`)은 `AtomicBool`로 선언되어 모든 probe partition이 공유한다. 한 partition에서 probe side에 NULL이 발견되면 `store(true, Ordering::Relaxed)`로 설정하고, 다른 partition들은 `load(Ordering::Relaxed)`로 이를 확인하여 null-aware 의미론을 유지한다 (`stream.rs:612-643`).

### 5.7 비동기 Stream 구현

`HashJoinStream`은 `futures::Stream` trait을 구현하며 (`stream.rs:231`), 핵심 로직은 `poll_next_impl()` (`stream.rs:411`)에서 state machine을 driving한다. `ready!()` 매크로와 `Poll::Pending/Ready`를 사용하여 Tokio runtime과 협력적 스케줄링을 수행한다.

## 6. Memory Management

### 6.1 Memory Pool 통합

`MemoryConsumer`와 `MemoryReservation`을 사용하여 DataFusion의 메모리 풀과 통합한다 (`exec.rs:1248-1249`):

- Build side 각 batch 수집 시 `reservation.try_grow(batch_size)?`로 메모리를 예약한다 (`exec.rs:1751`).
- Hash table 생성 시 `estimate_memory_size()`로 사전 추정하여 예약한다 (`exec.rs:1810-1820`).
- 예약 실패 시 `Result::Err`을 반환하여 OOM 전에 graceful하게 실패한다.

### 6.2 Spill 지원

현재 hash join 자체에 spill-to-disk 메커니즘은 구현되어 있지 않다. 메모리 초과 시 예약 실패로 쿼리가 에러를 반환한다. `collect_left_input()`의 `reservation.try_grow()` 호출 (`exec.rs:1751`)에서 이를 확인할 수 있다. 다만, DataFusion은 다른 operator (Sort 등)에서는 spill을 지원하므로, 전체 쿼리 계획의 메모리 조율이 가능하다.

### 6.3 메모리 추적

`JoinLeftData`는 `_reservation: MemoryReservation` 필드 (`exec.rs:202`)를 유지하여 생명주기 동안 정확한 메모리 accounting을 보장한다. Drop 시 자동으로 메모리 예약이 해제된다.

## 7. Join Types 지원

DataFusion은 다음 join type들을 지원한다:

| Join Type | Build Side 결과 필요 | Probe Side 결과 필요 | Final 단계 | 비고 |
|-----------|---------------------|---------------------|-----------|------|
| **Inner** | 매칭된 행 | 매칭된 행 | 없음 | probe 순서 보존 |
| **Left** | 모든 행 | 매칭된 행 + NULL | 미매칭 build 행 출력 | `visited_indices_bitmap` 사용 |
| **Right** | 매칭된 행 + NULL | 모든 행 | 없음 | probe 순서 보존 |
| **Full** | 모든 행 | 모든 행 | 미매칭 build 행 출력 | 양쪽 bitmap 필요 |
| **LeftSemi** | 매칭 존재 여부만 | - | 없음 | `contain_hashes()` 최적화 |
| **LeftAnti** | 매칭 없는 행 | - | 미매칭 build 행 출력 | `visited_indices_bitmap` 반전 |
| **RightSemi** | - | 매칭 존재 여부만 | 없음 | probe 순서 보존 |
| **RightAnti** | - | 매칭 없는 행 | 없음 | probe 순서 보존 |
| **LeftMark** | 매칭 여부 마커 | - | 미매칭 build 행 + false 마커 | |
| **RightMark** | - | 매칭 여부 마커 | 없음 | probe 순서 보존 |

`need_produce_result_in_final()` 함수로 final 단계가 필요한 join type을 판별하고, `adjust_indices_by_join_type()`으로 각 type에 맞는 인덱스 조정을 수행한다.

**Null-Aware Anti Join** (`exec.rs:354-367`): `null_aware` 플래그로 `NOT IN` 시맨틱을 지원한다. LeftAnti join에서만 사용되며, 단일 join key만 지원한다. Probe side에 NULL이 있으면 결과가 빈 집합이 된다 (`stream.rs:612-643`).

## 8. 추가 최적화

### 8.1 Dynamic Filter Pushdown

Build side의 min/max bounds를 계산하여 probe side scan에 range filter를 push down한다 (`shared_bounds.rs:146-184`). 이를 통해 불필요한 데이터 읽기를 사전 제거할 수 있다.

Partitioned 모드에서는 `HashTableLookupExpr` (`partitioned_hash_eval.rs:212`)을 사용하여 probe side 행이 build side hash table에 존재하는지 사전 검사하는 membership filter도 지원한다.

### 8.2 Fetch Limit

`LimitedBatchCoalescer`를 통해 `fetch` limit이 설정된 경우, 필요한 행 수만큼만 출력하고 조기 종료한다 (`stream.rs:425-427`).

## Key References

### 소스 코드 경로 (주요 함수)
- `datafusion/physical-plan/src/joins/hash_join/exec.rs` — `HashJoinExec`, `collect_left_input()`, `try_create_array_map()`
- `datafusion/physical-plan/src/joins/hash_join/stream.rs` — `HashJoinStream`, `poll_next_impl()`, `lookup_join_hashmap()`, `process_probe_batch()`, `process_unmatched_build_batch()`
- `datafusion/physical-plan/src/joins/join_hash_map.rs` — `JoinHashMapType`, `JoinHashMapU32`, `update_from_iter()`, `get_matched_indices_with_limit_offset()`
- `datafusion/physical-plan/src/joins/hash_join/partitioned_hash_eval.rs` — `HashExpr`, `HashTableLookupExpr`, `SeededRandomState`
- `datafusion/physical-plan/src/joins/hash_join/shared_bounds.rs` — `SharedBuildAccumulator`, `PushdownStrategy`, `PartitionBounds`
- `datafusion/physical-plan/src/joins/array_map.rs` — `ArrayMap` (perfect hash join)
- `datafusion/physical-plan/src/joins/utils.rs` — `OnceAsync`, `OnceFut`, `equal_rows_arr()`
- `datafusion/physical-plan/src/joins/mod.rs` — `PartitionMode`, `Map` enum

### 논문 / 참고 자료
- Lamb et al., "Apache Arrow DataFusion: A Fast, Embeddable, Modular Analytic Query Engine", SIGMOD 2024
  - DataFusion의 전반적 아키텍처, Volcano-style async execution model, 메모리 관리 설계 설명
- Boncz et al., "Balancing vectorized query execution with bandwidth-optimized storage", Ph.D. Thesis, Universiteit van Amsterdam, 2002
  - Chapter 5.3: JoinHashMap의 chained list 설계의 이론적 기반 (`join_hash_map.rs:46` 주석에서 직접 인용)
- hashbrown crate (Rust의 Swiss table 기반 HashMap 구현)
  - `HashTable<(u64, T)>`를 내부적으로 사용 (`join_hash_map.rs:28-29`)
