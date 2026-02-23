# Hash Join Partitioning 전략 — Cross-Engine 비교 분석

## 1. Overview

본 문서는 8개 OLAP 엔진의 hash join **partitioning 전략**을 비교 분석한다. 각 엔진의 상세 분석은 `<engine>/partitioning-strategy.md`에 있으며, 이 문서는 cross-engine 관점에서 설계 결정의 차이와 공통점을 정리한다.

---

## 2. 한눈에 보는 비교

| 엔진 | Partitioning 목적 | 파티션 수 | Build 파티셔닝 | Probe 파티셔닝 | Spill-to-Disk | Repartitioning |
|------|-------------------|-----------|---------------|---------------|---------------|----------------|
| **DuckDB** | 메모리 관리 (grace hash join) | 16 → 동적 증가 (radix bits) | Streaming append | ProbeAndSpill (probe+spill 동시) | O | Radix bits 증가 |
| **Velox** | 메모리 관리 (on-demand spill) | 8 (기본, configurable) | On-demand spill | Build spill 파티션 대응 | O | Recursive spilling (bit range 이동) |
| **ClickHouse** | In-memory 병렬 + External join | 256 (ConcurrentHJ) / 동적 (GraceHJ) | Bucket dispatch / Scatter | 공유 map 직접 조회 / Scatter+spill | O (GraceHJ) | Bucket 2x doubling |
| **DataFusion** | 쿼리 병렬 실행 | target_partitions (정적) | Hash repartitioning (plan 단계) | 동일 hash partitioning | X | 없음 (정적) |
| **Acero** | Lock-free 병렬 build | min(log2(DOP), log2(rows/4096)) | 3-phase (Partition→Build→Merge) | 없음 (global table 직접 probe) | X | 없음 |
| **RAPIDS cuDF** | 없음 (GPU TLP 의존) | N/A | 단일 global hash table (atomic CAS) | 2-pass (size estimation→retrieval) | X | 없음 |
| **Polars** | Thread-level 병렬 build | num_threads | Scatter(inner/left) / Filter(outer/semi) | 없음 (random access) | X | 없음 |
| **Umbra/HyPer** | 없음 (비파티셔닝 채택) | N/A | Morsel-local + CAS global insert | 직접 probe | O (buffer mgr) | N/A |

---

## 3. Partitioning 목적에 따른 분류

### 3.1 Type A: 메모리 관리 (Grace Hash Join)

**엔진**: DuckDB, Velox, ClickHouse (GraceHashJoin)

메모리에 전체 build 데이터가 올라가지 않을 때 파티셔닝을 통해 **spill-to-disk**를 수행한다. 파티션 단위로 build → probe를 반복하여, 한 번에 하나(또는 소수)의 파티션만 메모리에 올린다.

```
Build 데이터 → 파티셔닝 → 디스크 spill
                ↓
        파티션 i를 메모리에 load → HT 구축 → Probe → 결과 출력
                ↓
        파티션 i+1 반복 ... → 완료
```

**공통 특성:**
- Build 완료 후 메모리 적합성 판단
- 파티션 단위 build-probe 순환
- Probe 측도 동일 기준으로 파티셔닝하여 대응

**핵심 차이:**

| | DuckDB | Velox | ClickHouse (Grace) |
|---|---|---|---|
| **Trigger** | 데이터 크기 vs 예약 메모리 비교 | Memory arbitrator 호출 | `softCheck()` 메모리 초과 |
| **Trigger 수준** | Operator-level | System-level (arbitrator) | Operator-level |
| **초기 파티셔닝** | 항상 (Sink부터 16 파티션) | On-demand (spill 시에만) | 항상 (GraceHJ 선택 시) |
| **Repartitioning** | Radix bits 추가 (16→128 등) | Bit range shift (recursive) | Bucket 2x doubling |
| **Hash 재계산** | 불필요 (저장된 hash 상위 비트 활용) | 불필요 (bit range 이동) | 필요 (re-scatter) |
| **Probe 파티셔닝** | ProbeAndSpill (probe+spill 동시) | spillInput (active/spill 분류) | 별도 scatter pass |

### 3.2 Type B: In-Memory 병렬성 최적화

**엔진**: Acero, Polars, DataFusion (Partitioned mode), ClickHouse (ConcurrentHashJoin)

메모리 부족과 무관하게, **병렬 build의 동기화 비용을 제거**하기 위해 파티셔닝한다. 각 파티션에 독립적인 hash table을 구축하여 lock-free 병렬 build를 달성한다.

```
Build 데이터 → hash 파티셔닝 → 파티션별 독립 HT 구축 (lock-free)
                                      ↓
                              Merge → global HT (또는 파티션별 probe)
```

**공통 특성:**
- 파티션 간 데이터 독립성으로 lock 불필요
- 파티션 수는 병렬도(thread 수)에 비례
- Spill-to-disk 미지원 (in-memory 전용)

**핵심 차이:**

| | Acero | Polars | DataFusion | ClickHouse (Concurrent) |
|---|---|---|---|---|
| **파티션 수** | min(log2(DOP), log2(rows/4096)) | num_threads | target_partitions (config) | 256 (고정) |
| **Build 방식** | Counting sort → scatter | Count→offset→scatter (inner) / Filter (outer) | RepartitionExec (plan 단계) | TwoLevelHashMap bucket dispatch |
| **Merge** | 필요 (global table) | 불필요 (파티션별 probe) | 불필요 (파티션별 probe) | O(1) bucket swap |
| **Probe** | Global table 직접 | random access (hash_to_partition) | 파티션별 독립 | 공유 map 직접 |

### 3.3 Type C: Partitioning 불필요/거부

**엔진**: RAPIDS cuDF, Umbra/HyPer

명시적 partitioning을 수행하지 않는다. 각자 다른 이유로:

| | cuDF | Umbra/HyPer |
|---|---|---|
| **이유** | GPU massive TLP가 latency를 hide, 수백 GB/s bandwidth | Radix join 실험 후 기각 (Bandle et al. SIGMOD 2021) |
| **Build** | 단일 global table에 atomic CAS | Morsel-local materialize → global CAS insert |
| **Probe** | 2-pass (size estimate → retrieve) | Direct probe, 10-instruction hot path |
| **Cache 효율** | GPU 아키텍처가 자동 처리 | Bloom filter tag로 확보 |

---

## 4. 파티션 수 결정 전략 비교

파티션 수 결정은 엔진의 설계 철학을 반영하는 핵심 선택이다.

### 4.1 고정형 vs 동적형

```
고정형:  Acero, Polars, DataFusion, ClickHouse(Concurrent)
         ↓
         컴파일/계획 시점에 결정, 런타임 변경 없음

동적형:  DuckDB, Velox, ClickHouse(Grace)
         ↓
         런타임에 메모리 상황에 따라 파티션 수 조정
```

### 4.2 결정 기준 비교

| 엔진 | 결정 시점 | 결정 기준 | 공식/규칙 |
|------|----------|----------|----------|
| **DuckDB** | Finalize 단계 | 가용 메모리 vs 데이터 크기 | 가장 큰 파티션 ≤ 가용 메모리/4 |
| **Velox** | Spill 시점 | Memory arbitrator | 8 파티션 (기본), recursive로 증가 |
| **ClickHouse (Grace)** | Build 시 overflow | `softCheck()` 초과 | 현재 × 2 (doubling) |
| **ClickHouse (Concurrent)** | 컴파일 타임 | 하드코딩 | 256 (BITS_FOR_BUCKET=8) |
| **DataFusion** | 쿼리 계획 | 설정값 | target_partitions (기본: CPU 코어 수) |
| **Acero** | Build 시작 시 | DOP + 데이터 크기 | min(log2(DOP), log2(rows/4096)) |
| **Polars** | Build 시작 시 | Thread pool 크기 | POOL.current_num_threads() |

### 4.3 파티션 수 결정의 Trade-off

```
파티션 수 적음                          파티션 수 많음
    ↑                                        ↑
  - 파티션이 커서 메모리에 안 들어갈 수 있음      - 파티셔닝 오버헤드 증가
  - 병렬도 제한                              - 작은 파티션: cache 활용 유리
  - Build 시 경합 발생 가능                   - 너무 작으면 파티션 관리 비용 > 이점
```

DuckDB와 ClickHouse(Grace)는 이 trade-off를 **런타임에 동적으로** 해결한다. 나머지 엔진은 **사전 결정 후 고정**한다.

---

## 5. Repartitioning 메커니즘 비교

메모리 부족 시 파티션 수를 늘리는 repartitioning은 external hash join의 핵심 메커니즘이다.

### 5.1 지원 엔진별 비교

| | DuckDB | Velox | ClickHouse (Grace) |
|---|---|---|---|
| **방식** | Radix bits 추가 | Bit range shift (recursive) | Bucket 2x doubling |
| **예시** | 4bits→7bits (16→128) | Level 0: bit 48-50, Level 1: bit 51-53 | 4→8→16→32 buckets |
| **Hash 재계산** | **불필요** | **불필요** | **필요** (re-scatter) |
| **기존 파티션 활용** | 세분화 (파티션 0→{0..7}) | 새 bit range로 재분류 | 전체 re-scatter |
| **메모리 효율** | DESTROY_AFTER_DONE (즉시 해제) | Spill file split | FileBucket flush |
| **병렬 repartition** | Thread-local HT별 독립 수행 | Spiller 내부 처리 | Non-blocking random flush |
| **최대 깊이** | MAX_RADIX_BITS=12 (4096 파티션) | 4 levels (bit range 소진) | max_buckets 설정 |

### 5.2 Radix Bits 추가 vs Bucket Doubling

DuckDB의 radix bits 방식과 ClickHouse의 bucket doubling은 근본적으로 다른 접근이다:

**DuckDB — Radix Bits 추가:**
```
hash: [AAAA BBBB CCCC ...]
       ↑↑↑↑
       기존 4 bits → 파티션 0~15

hash: [AAAA BBB B CCCC ...]
       ↑↑↑↑ ↑↑↑
       새로운 7 bits → 파티션 0~127

기존 파티션 0의 데이터 → 새 파티션 {0,1,2,...,7}로 정확히 분할
Hash 재계산 불필요: 저장된 hash의 상위 비트를 더 많이 읽으면 됨
```

**ClickHouse — Bucket Doubling:**
```
기존: hash % 4 → bucket 0~3
새로: hash % 8 → bucket 0~7

기존 bucket 0의 데이터 → 새 bucket {0, 4}로 분산 (hash 값에 따라)
Re-scatter 필요: 모든 row를 새 hash function으로 재분류
```

**Velox — Recursive Bit Range Shift:**
```
Level 0: hash bits [48:50] → 8 파티션
Level 1: hash bits [51:53] → 8 sub-파티션 (기존 파티션 내)
Level 2: hash bits [54:56] → 8 sub-sub-파티션

다른 bit range를 사용하므로 기존 파티션과 독립적
한 파티션이 여전히 크면 해당 파티션만 다음 레벨로 진행
```

---

## 6. Build-Side Partitioning 비교

### 6.1 파티셔닝 시점

| 시점 | 엔진 | 설명 |
|------|------|------|
| **Streaming (Sink 시점)** | DuckDB, ClickHouse(Grace) | 데이터 도착 즉시 파티션에 append |
| **On-demand (Spill 시점)** | Velox | 메모리 부족 시에만 기존 데이터를 파티셔닝 |
| **Build 시작 시** | Acero, Polars | 모든 데이터 수집 후 한 번에 파티셔닝 |
| **Plan 시점** | DataFusion | 쿼리 계획에서 RepartitionExec 삽입 |
| **없음** | cuDF, Umbra | 단일 global table에 직접 삽입 |

### 6.2 파티셔닝 알고리즘

| 엔진 | 알고리즘 | 특징 |
|------|---------|------|
| **DuckDB** | Radix (상위 비트 bitmask+shift) | Streaming, histogram 불필요 (chunked storage) |
| **Velox** | HashBitRange (bit range 추출) | On-demand, 계층적 bit range |
| **ClickHouse** | getBucketFromHash (상위 8비트) | 256 고정 bucket, zero-copy dispatch |
| **Acero** | Counting sort (O(n)) | 2-pass: count → scatter, in-place 재배열 |
| **Polars** | hash_to_partition (곱셈 기반) | `(h * n) >> 64`, modulo bias 회피 |
| **DataFusion** | Hash repartitioning | RepartitionExec operator, seed 분리 |

### 6.3 Histogram 필요 여부

| | Histogram 필요 | 이유 |
|---|---|---|
| **Classic radix (학술)** | O | 연속 배열에 scatter하려면 prefix sum 필요 |
| **DuckDB** | X | Chunked storage (TupleDataCollection) — 동적 성장 |
| **Velox** | X | On-demand spill — batch 단위 append |
| **Acero** | O | Counting sort로 정확한 offset 계산 후 scatter |
| **Polars** | O (inner/left) | 3-stage: count → offset → scatter |

---

## 7. Probe-Side Partitioning 비교

### 7.1 접근 방식 분류

| 방식 | 엔진 | 설명 |
|------|------|------|
| **Probe+Spill 동시** | DuckDB | `ProbeAndSpill()`: 활성 파티션은 즉시 probe, 나머지 spill |
| **별도 Scatter** | ClickHouse(Grace), Velox | Probe 데이터를 먼저 파티셔닝한 후 해당 파티션별 probe |
| **파티셔닝 없음** | Acero, Polars, cuDF, Umbra | 단일/global table에 직접 probe |
| **Plan 단계 동일 파티셔닝** | DataFusion | Build와 같은 hash key로 사전 파티셔닝 |

### 7.2 Probe-Side Spill의 핵심 과제

Probe 데이터를 spill하려면 아직 처리되지 않은 파티션의 데이터를 디스크에 저장했다가 나중에 다시 읽어야 한다:

| | DuckDB | Velox | ClickHouse |
|---|---|---|---|
| **Spill 구조** | `ProbeSpill` (RadixPartitionedColumnData) | `SpillPartitionFunction` + Spiller | `FileBucket` (left/right 독립 파일) |
| **Build 파티셔닝과 일치** | 동일 radix bits | 동일 bit range | 동일 bucket 수 |
| **재사용** | `PrepareNextProbe()`로 해당 파티션만 꺼냄 | `IterableSpillPartitionSet` 순회 | Stage 3에서 bucket별 reload |

---

## 8. In-Memory vs External: 이중 전략

대부분의 엔진은 in-memory와 external 상황에서 **다른 전략**을 사용한다:

| 엔진 | In-Memory 전략 | External 전략 | 전환 기준 |
|------|---------------|---------------|----------|
| **DuckDB** | `Unpartition()` → 단일 HT | 파티션별 build-probe 순환 | reservation < total_size |
| **Velox** | Non-partitioned build | Spill + recursive repartition | Memory arbitrator trigger |
| **ClickHouse** | ConcurrentHashJoin (256 bucket) | GraceHashJoin (dynamic bucket) | 설정 또는 메모리 상황 |
| **DataFusion** | CollectLeft / Partitioned | N/A (spill 미지원) | — |
| **Acero** | Partition→Build→Merge | N/A (spill 미지원) | — |
| **Polars** | Scatter/Filter 기반 | N/A (spill 미지원) | — |
| **cuDF** | 단일 global HT | N/A (GPU VRAM 한계) | — |
| **Umbra** | Non-partitioned + Bloom tag | Buffer manager 투명 spill | Page eviction |

**관찰**: Spill을 지원하는 3개 엔진(DuckDB, Velox, ClickHouse)은 모두 in-memory에서의 파티셔닝 역할과 external에서의 역할이 다르다. DuckDB는 in-memory에서 파티셔닝을 무시(`Unpartition`)하고, Velox는 in-memory에서 파티셔닝 자체를 하지 않는다.

---

## 9. Classic Radix Join과의 관계

"Radix partitioning"이라는 용어는 엔진마다 다른 의미로 사용된다:

### 9.1 Classic Radix Join (Boncz, Manegold, ICDE 1999)

- **목적**: TLB/cache 최적화
- **방법**: Multi-pass partitioning → 각 파티션이 L1/L2 cache에 fit
- **Build+Probe 양쪽** 모두 파티셔닝
- **항상 수행** (in-memory 전용 기법)

### 9.2 각 엔진의 입장

| 엔진 | Classic radix join과의 관계 |
|------|---------------------------|
| **DuckDB** | "Radix"라는 이름을 쓰지만 목적이 다름 (메모리 관리). In-memory에서는 파티셔닝 무시 |
| **Velox** | Hash bit range 사용하지만 cache 최적화 목적 아님 (spill 관리) |
| **ClickHouse** | Radix와 무관. Hash modulo 기반 bucket 분배 |
| **Acero** | Hash 상위 비트 사용하지만 목적은 lock-free build (cache 아님) |
| **Polars** | 곱셈 기반 hash-to-partition. Cache 최적화 아님 |
| **Umbra** | Classic radix join 실험 후 **기각**. "59개 TPC-H join 중 1개만 개선" |
| **cuDF** | GPU에서 radix join은 불필요 (TLP가 latency hide) |

### 9.3 핵심 결론

**어떤 production 엔진도 classic radix join을 기본 전략으로 채택하지 않았다.** Umbra의 실험(Bandle et al., SIGMOD 2021)이 이를 가장 명확하게 보여준다. "Radix"라는 이름이 붙은 구현(DuckDB)도 실제로는 TLB/cache 최적화가 아닌 메모리 관리 목적이다.

현대 OLAP 엔진에서 cache 효율은 다른 방식으로 달성된다:
- **Vectorized execution** (DuckDB, Velox): 2048-tuple batch 처리
- **SIMD tag matching** (Velox, Acero): 16-way/32-way parallel comparison
- **Bloom filter tags** (Umbra): 4-bit Bloom filter in pointer
- **Salt/Stamp** (DuckDB, Acero): Early filtering으로 불필요한 key 비교 회피

---

## 10. GPU vs CPU: 근본적 차이

| 관점 | CPU 엔진들 | GPU (cuDF) |
|------|----------|-----------|
| **Partitioning** | Cache miss 감소 또는 메모리 관리 목적 | 불필요 — massive TLP가 latency hide |
| **Hash table** | 엔진별 custom (salt/tag/stamp) | cuco lock-free open addressing |
| **Build 동시성** | 수~수십 thread, partition 분리 또는 CAS | 수만 thread, 1 thread = 1 row, atomic CAS |
| **Probe 동시성** | Morsel/partition 단위 | 1 CG(2 threads) = 1 probe row |
| **Output 크기** | Dynamic growth | 2-pass: size estimation → exact allocation |
| **Spill** | 지원 (DuckDB, Velox, ClickHouse) | 미지원 (GPU VRAM 한계) |
| **Memory bandwidth** | ~50 GB/s (DDR5) | ~900 GB/s (HBM3) |

GPU의 18배 bandwidth와 massive parallelism은 CPU에서 partitioning이 해결하던 문제를 하드웨어 수준에서 해결한다. 이것이 cuDF가 명시적 partitioning 없이도 높은 성능을 달성할 수 있는 근본적 이유이다.

---

## 11. 설계 결정 트리

엔진 설계자가 partitioning 전략을 결정할 때의 판단 흐름:

```
데이터가 메모리에 들어가는가?
│
├─ YES: In-memory join
│   │
│   ├─ GPU인가?
│   │   └─ YES → 파티셔닝 불필요 (cuDF)
│   │
│   ├─ 병렬 build에서 lock contention이 문제인가?
│   │   ├─ YES → Partition-based parallel build (Acero, Polars)
│   │   └─ NO → CAS 기반 단일 HT (Umbra, DuckDB in-memory)
│   │
│   └─ Radix join으로 cache 효율을 높일 수 있는가?
│       └─ 대부분 NO (Umbra 실험 결과)
│
└─ NO: External join 필요
    │
    ├─ 언제 파티셔닝을 시작하는가?
    │   ├─ 항상 (DuckDB: Sink부터)
    │   ├─ On-demand (Velox: arbitrator trigger)
    │   └─ 항상 (ClickHouse Grace: 선택 시점부터)
    │
    ├─ Repartitioning이 필요한가?
    │   ├─ YES → Radix bits 추가 (DuckDB) / Recursive spill (Velox) / Bucket doubling (ClickHouse)
    │   └─ NO → 초기 파티션으로 충분
    │
    └─ Probe 측도 파티셔닝하는가?
        └─ YES (모든 spill 지원 엔진)
           ├─ Probe+spill 동시 (DuckDB)
           └─ 별도 scatter (ClickHouse, Velox)
```

---

## 12. 핵심 Insights

### 12.1 Partitioning은 "필요악"이다

어떤 엔진도 partitioning 자체를 성능 최적화로 보지 않는다:
- **In-memory**: DuckDB는 `Unpartition()`으로 합치고, Velox는 아예 파티셔닝하지 않음
- **External**: 메모리 한계 때문에 어쩔 수 없이 파티셔닝
- **병렬 build**: Lock contention 회피 수단 — 성능이 아닌 정확성 문제

### 12.2 Hash 재계산 비용이 설계를 결정한다

DuckDB와 Velox는 repartitioning 시 **hash 재계산이 불필요**하도록 설계했다 (상위 비트/다른 bit range 활용). ClickHouse는 re-scatter가 필요하다. 이 차이가 대량 데이터에서의 repartitioning 비용을 결정한다.

### 12.3 Probe-Side 파티셔닝은 가장 어려운 문제

Build 측은 blocking operator이므로 데이터 전체가 도착한 후 파티셔닝할 수 있지만, probe 측은 streaming이다. DuckDB의 `ProbeAndSpill()` (probe+spill 동시 수행)이 가장 효율적인 접근으로, 별도 scatter pass 없이 한 chunk 안에서 active/spill을 분리한다.

### 12.4 Spill 미지원은 의도적 선택이다

DataFusion, Acero, Polars, cuDF가 spill을 지원하지 않는 것은 구현 부족이 아니라 설계 선택이다:
- **DataFusion**: TODO 주석 존재하지만 미구현 — 쿼리 엔진 특성상 메모리 관리를 외부에 위임
- **Acero**: Arrow 생태계의 in-memory processing 철학
- **Polars**: DataFrame 라이브러리 — OOM은 사용자 책임
- **cuDF**: GPU VRAM 한계는 하드웨어 제약

### 12.5 Thread 수 = 파티션 수는 단순하지만 효과적

Polars의 `num_threads` 기반 파티셔닝과 Acero의 `DOP` 기반 파티셔닝은 **1 thread = 1 partition**이라는 단순한 원칙으로 lock contention을 완전히 제거한다. 복잡한 동적 repartitioning 없이도 in-memory 워크로드에서 충분한 병렬성을 달성한다.

---

## 13. Key References

### 엔진별 상세 분석

| 엔진 | 파일 |
|------|------|
| DuckDB | [`duckdb/partitioning-strategy.md`](duckdb/partitioning-strategy.md) |
| Velox | [`velox/partitioning-strategy.md`](velox/partitioning-strategy.md) |
| ClickHouse | [`clickhouse/partitioning-strategy.md`](clickhouse/partitioning-strategy.md) |
| DataFusion | [`datafusion/partitioning-strategy.md`](datafusion/partitioning-strategy.md) |
| Acero | [`acero/partitioning-strategy.md`](acero/partitioning-strategy.md) |
| RAPIDS cuDF | [`rapids-cudf/partitioning-strategy.md`](rapids-cudf/partitioning-strategy.md) |
| Polars | [`polars/partitioning-strategy.md`](polars/partitioning-strategy.md) |
| Umbra/HyPer | [`umbra-hyper/partitioning-strategy.md`](umbra-hyper/partitioning-strategy.md) |

### 핵심 논문

1. **"Main-Memory Hash Joins on Multi-Core CPUs: Tuning to the Underlying Hardware"** — Stefan Manegold, Peter Boncz, ICDE 1999. Classic radix join 원 논문.
2. **"To Partition, or Not to Partition, That is the Join Question in a Real System"** — Maximilian Bandle, Jana Giceva, Thomas Neumann, SIGMOD 2021. Radix join의 실용성 재평가.
3. **"Saving Private Hash Join: How to Implement an External Hash Join within Limited Memory"** — Kuiper et al., VLDB 2024. DuckDB의 external hash join.
4. **"Morsel-Driven Parallelism"** — Viktor Leis et al., SIGMOD 2014. Morsel 기반 병렬 실행 모델.
5. **"Velox: Meta's Unified Execution Engine"** — Pedro Pedreira et al., VLDB 2022.
6. **"Triton Join: Efficiently Scaling to a Large Join State on GPUs"** — Lutz et al., SIGMOD 2022. GPU hash join.
