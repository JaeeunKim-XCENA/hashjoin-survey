# Apache DataFusion — Hash Join Partitioning 전략 심층 분석

## 요약

DataFusion의 hash join partitioning은 **쿼리 계획 단계에서 결정되는 정적 파티셔닝**을 기반으로 한다. `PartitionMode` enum (`joins/mod.rs:85`)으로 세 가지 전략(CollectLeft, Partitioned, Auto)을 제공하며, 옵티마이저가 통계 기반으로 최적 모드를 선택한다.

핵심 특성:
- **정적 파티셔닝**: 실행 전 쿼리 옵티마이저가 partition mode를 결정하며, 실행 중 동적 repartitioning은 없음
- **두 가지 실행 패턴**: CollectLeft (build side 공유) vs Partitioned (독립 파티션 병렬 처리)
- **Spill 미지원**: hash join 자체에 spill-to-disk 메커니즘이 없으며, 메모리 초과 시 에러 반환
- **Hash seed 분리**: `RepartitionExec`과 `HashJoinExec`이 서로 다른 hash seed를 사용하여 collision 방지
- **Dynamic filter pushdown**: 파티션 간 build-side 정보를 조율하여 probe-side scan에 필터를 push down

---

## 1. Partitioning 개요

### 1.1 PartitionMode enum

`PartitionMode` (`joins/mod.rs:83-94`)은 hash join의 파티셔닝 전략을 정의한다:

```rust
pub enum PartitionMode {
    /// 양쪽 입력을 join key 기반 hash로 repartition
    Partitioned,
    /// Build side를 단일 파티션으로 수집
    CollectLeft,
    /// 옵티마이저가 통계 기반으로 자동 선택
    Auto,
}
```

`Auto` 모드는 실행 시점에는 존재하면 안 되며, `execute()` 호출 시 에러를 반환한다 (`exec.rs:1286-1291`).

### 1.2 파티션 수 결정

파티션 수는 DataFusion의 **물리 계획 최적화 단계**에서 결정된다. `EnforceDistribution` 옵티마이저 규칙이 `required_input_distribution()` (`exec.rs:1089-1111`)의 요구사항에 따라 `RepartitionExec` 또는 `CoalescePartitionsExec`를 삽입한다.

- **CollectLeft**: build side에 `CoalescePartitionsExec`가 삽입되어 단일 파티션으로 합쳐지고, probe side는 원래 partitioning을 유지한다.
- **Partitioned**: 양쪽에 `RepartitionExec`이 삽입되어 join key 기반 hash partitioning이 적용된다. 파티션 수는 `target_partitions` 설정값에 의해 결정된다.

### 1.3 Hash Seed 분리

`HASH_JOIN_SEED` (`exec.rs:95-97`)는 `('J', 'O', 'I', 'N')` 시드를 사용한다:

```rust
pub(crate) const HASH_JOIN_SEED: SeededRandomState =
    SeededRandomState::with_seeds('J' as u64, 'O' as u64, 'I' as u64, 'N' as u64);
```

이는 `RepartitionExec`의 `(0, 0, 0, 0)` 시드(`REPARTITION_RANDOM_STATE`)와 의도적으로 다르게 설정되어, hash partitioning과 hash join의 hash 값이 달라 collision 패턴이 겹치지 않도록 한다 (`exec.rs:95` 주석). `SeededRandomState` (`partitioned_hash_eval.rs:42-65`)는 ahash의 `RandomState`를 래핑하면서 시드를 보존하여 직렬화에 활용할 수 있게 한다.

---

## 2. Build-Side Partitioning

### 2.1 CollectLeft 모드

CollectLeft 모드에서 build side는 **단일 파티션**으로 수집된다 (`exec.rs:1244-1264`):

```rust
PartitionMode::CollectLeft => self.left_fut.try_once(|| {
    let left_stream = self.left.execute(0, Arc::clone(&context))?;
    // ...
    Ok(collect_left_input(
        // ...
        self.right().output_partitioning().partition_count(),  // probe_threads_count
        // ...
    ))
}),
```

- `OnceAsync<JoinLeftData>` (`exec.rs:643`)를 통해 build 작업을 **정확히 한 번**만 실행한다.
- 결과 `JoinLeftData`는 `Arc`로 래핑되어 모든 probe partition stream에 **공유**된다.
- `probe_threads_count` 파라미터로 probe side의 partition 수를 전달하여, outer join에서의 동기화에 활용한다.
- `Distribution::SinglePartition` 요구 (`exec.rs:1091-1094`)로 인해 build side 앞에 `CoalescePartitionsExec`가 삽입된다.

### 2.2 Partitioned 모드

Partitioned 모드에서 build side는 **파티션별 독립 빌드**를 수행한다 (`exec.rs:1265-1285`):

```rust
PartitionMode::Partitioned => {
    let left_stream = self.left.execute(partition, Arc::clone(&context))?;
    // ...
    OnceFut::new(collect_left_input(
        // ...
        1,  // probe_threads_count = 1 (각 파티션이 독립)
        // ...
    ))
}
```

- 각 파티션에 독립적인 `OnceFut`를 생성한다 (CollectLeft의 `OnceAsync`와 달리 공유 없음).
- `self.left.execute(partition, ...)` / `self.right.execute(partition, ...)`로 같은 partition 번호의 stream을 가져온다 (`exec.rs:1266, 1325`).
- `Distribution::HashPartitioned(left_expr)` / `Distribution::HashPartitioned(right_expr)` 요구 (`exec.rs:1095-1105`)로 인해 양쪽에 `RepartitionExec`이 삽입된다.
- 파티션 수 일치 검증: `left_partitions == right_partitions` 조건이 `execute()` 시작 시 검사된다 (`exec.rs:1213-1218`).

### 2.3 Build 데이터 수집 과정

`collect_left_input()` (`exec.rs:1713`)은 두 모드 모두에서 동일한 로직을 사용한다:

1. `left_stream`에서 모든 batch를 `try_fold`로 소비한다 (`exec.rs:1739-1762`).
2. 각 batch마다 `reservation.try_grow(batch_size)?`로 메모리를 예약한다 (`exec.rs:1751`).
3. `PartitionBounds`(min/max bounds)를 누적 계산한다 (dynamic filter용).
4. 수집 완료 후 ArrayMap 또는 JoinHashMap을 생성한다 (`exec.rs:1785-1851`).
5. 결과를 `JoinLeftData`로 캡슐화하여 반환한다.

주석에 `// Decide if we spill or not` (`exec.rs:1748`)이라는 TODO 성격의 코멘트가 있으나, 실제로는 spill 로직 없이 `try_grow` 실패 시 에러를 반환한다.

---

## 3. Probe-Side Partitioning

### 3.1 CollectLeft 모드

Probe side는 **원래의 partitioning을 그대로 유지**한다. `Distribution::UnspecifiedDistribution` (`exec.rs:1093`)을 요구하므로 probe side에 대한 repartitioning 강제가 없다. 각 probe partition은 독립적인 `HashJoinStream`을 생성하여 (`exec.rs:1325`) 공유된 hash table에 대해 probe를 수행한다.

Output partitioning은 probe side의 partitioning을 따른다:
```rust
PartitionMode::CollectLeft => {
    asymmetric_join_output_partitioning(left, right, &join_type)?
}
```

### 3.2 Partitioned 모드

Probe side도 build side와 **동일한 join key 기반 hash partitioning**으로 repartition된다. 같은 join key를 가진 행들이 같은 파티션에 모이므로, 각 파티션이 독립적으로 build-probe를 완결할 수 있다.

Output partitioning은 양쪽 partitioning의 대칭적 조합으로 결정된다:
```rust
PartitionMode::Partitioned => {
    symmetric_join_output_partitioning(left, right, &join_type)?
}
```

### 3.3 Probe 실행 흐름

`HashJoinStream`의 state machine (`stream.rs:429-453`)은 다음 순서로 진행한다:

1. **WaitBuildSide** → build future를 poll하여 hash table 완성을 대기
2. **WaitPartitionBoundsReport** → (선택적) dynamic filter가 모든 파티션에서 보고될 때까지 대기
3. **FetchProbeBatch** → probe side에서 batch를 하나씩 가져옴
4. **ProcessProbeBatch** → hash table lookup으로 join 매칭 수행
5. **ExhaustedProbeSide** → outer/anti join의 미매칭 행 출력
6. **Completed** → 완료

---

## 4. Spill-to-Disk 메커니즘

### 4.1 현재 상태: 미지원

DataFusion의 `HashJoinExec`은 **spill-to-disk을 지원하지 않는다**. 소스 코드 분석 결과:

- `collect_left_input()`에서 `reservation.try_grow(batch_size)?` (`exec.rs:1751`)가 메모리 예약 실패 시 `Result::Err`를 반환하여 쿼리 전체가 에러로 종료된다.
- `exec.rs:1748`에 `// Decide if we spill or not`이라는 주석이 존재하지만, 실제 spill 로직은 구현되어 있지 않다.
- Grace hash join이나 recursive partitioning 메커니즘은 코드베이스에 존재하지 않는다.

### 4.2 메모리 관리 전략

Spill 대신 DataFusion은 다음과 같은 메모리 관리를 수행한다:

1. **MemoryConsumer/MemoryReservation**: build side 각 batch 수집 시 메모리 풀에 예약을 시도한다 (`exec.rs:1248-1249`).
2. **Hash table 사전 추정**: `estimate_memory_size()`로 hash table 메모리를 미리 추정하여 예약한다 (`exec.rs:1810-1820`).
3. **RAII 기반 해제**: `JoinLeftData`의 `_reservation` 필드 (`exec.rs:202`)가 drop 시 자동으로 메모리 예약을 해제한다.
4. **Partitioned 모드의 간접적 완화**: 양쪽 데이터를 `target_partitions`만큼 분할하므로, 각 파티션의 hash table 크기가 줄어들어 메모리 소비가 분산된다.

### 4.3 다른 operator의 spill 지원

DataFusion은 Sort 등 다른 operator에서는 spill을 지원하므로, 전체 쿼리 계획 수준에서 메모리 조율이 가능하다. 그러나 hash join 자체가 메모리에 맞지 않으면 대안이 없다.

---

## 5. Dynamic Filter Pushdown과 파티션 간 조율

### 5.1 SharedBuildAccumulator

`SharedBuildAccumulator` (`shared_bounds.rs:216`)는 여러 파티션의 build-side 정보를 수집하고 조율하는 구조체이다. 모든 파티션이 build를 완료한 후에야 dynamic filter를 업데이트하여, 불완전한 필터로 인한 정합성 문제를 방지한다.

```rust
pub(crate) struct SharedBuildAccumulator {
    inner: Mutex<AccumulatedBuildData>,
    barrier: Barrier,                     // tokio::sync::Barrier
    dynamic_filter: Arc<DynamicFilterPhysicalExpr>,
    on_right: Vec<PhysicalExprRef>,
    repartition_random_state: SeededRandomState,
    probe_schema: Arc<Schema>,
}
```

### 5.2 Partition 모드별 동작

**CollectLeft 모드** (`shared_bounds.rs:402-458`):
- 단일 build side의 bounds + membership predicate를 AND로 결합한다.
- 모든 probe partition이 같은 데이터를 보고하므로 deduplication 로직이 있다 (`shared_bounds.rs:382-385`).

**Partitioned 모드** (`shared_bounds.rs:460-579`):
- 각 파티션의 build data를 개별적으로 수집한다.
- 최종적으로 **CASE expression**을 생성하여 probe row를 올바른 파티션의 필터로 라우팅한다:
  ```
  CASE (hash_repartition(join_keys) % num_partitions)
    WHEN 0 THEN (col >= min_0 AND col <= max_0) AND membership_check_0
    WHEN 1 THEN (col >= min_1 AND col <= max_1) AND membership_check_1
    ...
    ELSE false
  END
  ```
- 라우팅 hash는 `HashExpr` (`partitioned_hash_eval.rs:75`)에 `RepartitionExec`과 동일한 `(0,0,0,0)` 시드를 사용하여, 파티셔닝과 일관된 라우팅을 보장한다.

### 5.3 Barrier 기반 동기화

`tokio::sync::Barrier` (`shared_bounds.rs:219`)를 사용하여 모든 파티션의 build 완료를 동기화한다:
- `expected_calls`는 CollectLeft에서는 probe side partition 수, Partitioned에서는 build side partition 수로 설정된다 (`shared_bounds.rs:308-321`).
- `barrier.wait().await.is_leader()`가 `true`인 마지막 도착 파티션만이 필터를 생성/업데이트한다 (`shared_bounds.rs:397`).
- Probe stream은 `WaitPartitionBoundsReport` 상태 (`stream.rs:433`)에서 filter 갱신 완료를 대기한 후 probe를 시작한다.

### 5.4 PushdownStrategy

`PushdownStrategy` (`shared_bounds.rs:232-240`)는 build side 크기에 따라 필터 타입을 결정한다:
- **InList**: 작은 build side일 때 IN 리스트로 정확한 값 매칭 (Bloom filter 활용 가능)
- **Map**: 큰 build side일 때 hash table 참조(`HashTableLookupExpr`)로 membership 체크
- **Empty**: 빈 파티션 (필터 생성 불필요)

---

## 6. DuckDB와의 비교

| 항목 | DataFusion | DuckDB |
|------|-----------|--------|
| **파티셔닝 시점** | 쿼리 계획 단계 (정적) | 실행 중 동적 repartitioning 가능 |
| **파티셔닝 방식** | `RepartitionExec`에 의한 hash partitioning | Radix partitioning (hash 상위 비트) |
| **초기 파티션 수** | `target_partitions` 설정값 | 고정 16개 (INITIAL_RADIX_BITS=4) |
| **동적 repartitioning** | 없음 | Radix bits 증가로 세분화 (4->7 bits = 16->128 파티션) |
| **Spill-to-disk** | **미지원** (메모리 초과 시 에러) | Grace hash join 방식으로 지원 |
| **메모리 부족 대응** | `try_grow()` 실패 -> 쿼리 에러 | 파티션 단위 spill + 순차 처리 |
| **Hash seed** | Join/Repartition 별도 seed | 단일 hash 값을 다른 bit range로 사용 |
| **Probe-side spill** | 없음 | Active/spill 분리 (`RadixPartitioning::Select`) |
| **실행 모델** | Async/await Volcano pull | Push-based pipeline |

핵심 차이점: DuckDB는 radix partitioning을 기반으로 **실행 중 메모리 상황에 따라 동적으로 파티션 수를 조절**하고 spill-to-disk을 수행하는 반면, DataFusion은 **쿼리 계획 시점에 파티션 전략을 고정**하고 spill 없이 인메모리 처리에 집중한다. DataFusion의 Partitioned 모드는 데이터를 분산하여 개별 hash table 크기를 줄이는 효과가 있지만, 특정 파티션이 메모리에 맞지 않는 경우에 대한 fallback 메커니즘이 없다.

---

## Key References

### 소스 코드 경로 (주요 함수)

- `datafusion/physical-plan/src/joins/mod.rs` -- `PartitionMode` enum (line 83-94), `Map` enum
- `datafusion/physical-plan/src/joins/hash_join/exec.rs` -- `HashJoinExec` 구조체 (line 623-666), `HASH_JOIN_SEED` (line 95-97)
  - `required_input_distribution()` (line 1089-1111): 모드별 분배 요구사항
  - `execute()` (line 1200-1343): 모드별 build/probe stream 생성
  - `collect_left_input()` (line 1713-1900+): build side 데이터 수집 및 hash table 빌드
  - `compute_properties()` (line 847-919): output partitioning 결정
- `datafusion/physical-plan/src/joins/hash_join/stream.rs` -- `HashJoinStream` state machine
  - `collect_build_side()` (line 479-548): build data 수집 및 dynamic filter 보고
  - `wait_for_partition_bounds_report()` (line 465-474): 파티션 간 동기화 대기
- `datafusion/physical-plan/src/joins/hash_join/shared_bounds.rs` -- `SharedBuildAccumulator` (line 216-588)
  - `new_from_partition_mode()` (line 298-346): 파티션 모드별 초기화
  - `report_build_data()` (line 360-587): 파티션별 build data 수집 및 필터 생성
  - `PartitionBounds` (line 66-80): 파티션별 min/max bounds
  - `PushdownStrategy` (line 232-240): InList vs Map vs Empty
- `datafusion/physical-plan/src/joins/hash_join/partitioned_hash_eval.rs` -- hash 및 lookup expression
  - `SeededRandomState` (line 42-65): 시드 보존 RandomState 래퍼
  - `HashExpr` (line 75-206): hash 계산 expression (파티션 라우팅용)
  - `HashTableLookupExpr` (line 212-352): hash table membership 체크 expression
- `datafusion/physical-plan/src/joins/utils.rs` -- `OnceAsync`, `OnceFut` (build side 공유 메커니즘)
