# Hash Join Survey — Cross-Engine 비교 분석

## 1. Overview

본 서베이는 8개 Modern OLAP 엔진의 Hash Join 구현을 **소스 코드 우선**으로 분석하고, 핵심 설계 결정을 비교한다.

### 대상 엔진

| 엔진 | 언어 | 실행 모델 | 소스 분석 |
|------|------|----------|----------|
| **DuckDB** | C++ | Vectorized push-based | O (소스코드) |
| **Velox** (Meta) | C++ | Vectorized pipeline | O (소스코드) |
| **ClickHouse** | C++ | Column-oriented | O (소스코드) |
| **DataFusion** | Rust | Volcano-style async pull | O (소스코드) |
| **Arrow Acero** | C++ | Task-based push | O (소스코드) |
| **RAPIDS cuDF** | CUDA/C++ | GPU massively parallel | O (소스코드) |
| **Polars** | Rust | Data-parallel (Rayon) | O (소스코드) |
| **Umbra/HyPer** | C++ | Compiled morsel-driven | X (논문 기반) |

### 분석 방법론

1. **소스 코드 분석** (최우선): 7개 엔진의 GitHub 저장소를 shallow clone + sparse checkout하여 핵심 파일을 직접 분석
2. **논문/아티클**: Umbra/HyPer는 공개 소스가 없으므로 SIGMOD/VLDB 논문을 기반으로 분석
3. **공식 문서/블로그**: 추가 컨텍스트 제공 시 활용

---

## 2. Hash Table 구조 비교

| 엔진 | Hash Table 유형 | Probing 방식 | Key 특징 |
|------|----------------|-------------|---------|
| **DuckDB** | Open addressing (custom) | Linear probing + 16-bit salt | Salt로 빠른 필터링, 48-bit pointer packing |
| **Velox** | F14-inspired buckets | 16-way SIMD probing + 7-bit tag | 128-byte bucket, SSE2/NEON SIMD 비교 |
| **ClickHouse** | 30+ variants 자동 선택 | Linear probing (HashMap) / Direct (FixedHashMap) | 키 타입별 최적 variant 선택 (UInt8→FixedHashMap, String→SavedHash 등) |
| **DataFusion** | hashbrown (Swiss Table) + chained list | Swiss Table probing | `(hash, row_index)` pair + `next[]` 배열로 chain |
| **Acero** | Swiss Table (custom) | Block-based (8 slots) + 7-bit stamp | SIMD early_filter, AVX2 가속, row-oriented key encoding |
| **cuDF** | cuco::static_multiset | Double hashing + CG(2) | GPU lock-free, open addressing, 0.5 load factor |
| **Polars** | hashbrown (Swiss Table) | Swiss Table (SIMD) | ahash (정수) / xxh3 (문자열), folded_multiply combine |
| **Umbra/HyPer** | Unchained (Umbra) / Chained+tag (HyPer) | Bloom tag filtering | 4-bit Bloom filter in pointer, 10 instruction hot path |

### 핵심 설계 패턴

- **Salt/Tag/Stamp 기반 Early Filtering**: DuckDB (16-bit salt), Velox (7-bit tag), Acero (7-bit stamp), Umbra (4-bit Bloom filter) — 모두 hash 값의 일부를 포인터 또는 control byte에 내장하여 불필요한 key 비교를 회피
- **Direct-Address Table**: DuckDB (PerfectHashJoin), ClickHouse (FixedHashMap), Velox (kArray mode), DataFusion (ArrayMap) — 단일 정수 키의 범위가 작을 때 O(1) 직접 접근
- **키 타입 적응형 선택**: ClickHouse가 가장 극단적 (30+ variants), Velox도 3개 모드 (kHash/kArray/kNormalizedKey) 자동 전환

---

## 3. Build/Probe Phase 비교

### Build Phase

| 엔진 | Build 측 선택 | Build 핵심 특징 |
|------|-------------|----------------|
| **DuckDB** | RHS (Right) 고정 | Thread-local HT → Combine → Parallel finalize (CAS) |
| **Velox** | 고정 (plan 기반) | Per-driver HT → Barrier → Last driver merges → Parallel table build |
| **ClickHouse** | 고정 (Right) | Per-slot dispatch → TwoLevelHashMap → O(1) bucket merge |
| **DataFusion** | 고정 (Left) | Async collect → hashbrown insert (역순 batch 처리) |
| **Acero** | 고정 (plan 기반) | 3-phase: Partition → Per-partition build → Merge |
| **cuDF** | 작은 테이블 자동 선택 | cuco `insert()` / `insert_if()` — GPU kernel, atomic CAS |
| **Polars** | 짧은 relation 자동 선택 | 3-stage: partition count → scatter → per-partition build |
| **Umbra** | 옵티마이저 결정 | 2-phase: NUMA-local materialize → lock-free CAS insert |

### Probe Phase

| 엔진 | Probe 핵심 특징 |
|------|----------------|
| **DuckDB** | Vectorized 2048-tuple batch, salt 비교 → key 비교 → chain traversal |
| **Velox** | 4-way interleaved SIMD probing, memory latency hiding |
| **ClickHouse** | Template-based dispatch (`JoinKind × JoinStrictness`), ScatteredBlock partial processing |
| **DataFusion** | State machine (async), limit/offset 기반 분할 처리 |
| **Acero** | Mini-batch 처리, Bloom filter pre-filtering, SIMD stamp matching |
| **cuDF** | 2-pass (size estimation → retrieval), cooperative group probing |
| **Polars** | Partition lookup → hash table get → parallel materialization |
| **Umbra** | Compiled code, Bloom tag filtering, 10 instruction hot path |

---

## 4. 병렬성 모델 비교 (핵심 섹션)

### Pattern A: Morsel-Driven Parallelism

**대표 엔진**: DuckDB, Umbra/HyPer

Morsel (≈100K tuples)을 작업 단위로, 중앙 Dispatcher가 NUMA-aware하게 thread에 할당하는 모델.

- **DuckDB**: Thread-local hash table → combine → parallel finalize (CAS). Build 시 skew 감지하여 단일 스레드 폴백. External join에서는 파티션 단위로 BUILD → PROBE → SCAN_HT 순환.
- **Umbra**: NUMA-local storage에 materialize → 정확한 크기의 global hash table 할당 → lock-free CAS 삽입. Read-only probe에서 동기화 불필요.

**핵심 동기화**: Barrier synchronization (build 완료 후 probe 시작), CAS 기반 lock-free insert.

### Pattern B: Parallel Build → Merge → Shared Probe

**대표 엔진**: Velox, ClickHouse (ConcurrentHashJoin)

각 빌드 스레드가 독립적인 hash table을 구축한 후 merge하여 공유 hash table을 만드는 모델.

- **Velox**: Per-driver HashTable → `allPeersFinished()` barrier → Last driver가 merge + `parallelJoinBuild()` (partition-based parallel insert) → 공유 hash table로 probe.
- **ClickHouse**: N개의 독립 `HashJoin` 인스턴스 + `TwoLevelHashMap` → `onBuildPhaseFinish()`에서 O(1) bucket swap으로 merge → 공유 map으로 direct probe.

**핵심 차이**: Velox는 partition-by-range 후 parallel insert, ClickHouse는 TwoLevelHashMap의 bucket-level ownership으로 O(1) merge.

### Pattern C: Partition-Based Parallelism

**대표 엔진**: Acero, Polars, DataFusion (Partitioned mode)

데이터를 hash 기반으로 partition하여 각 partition을 독립적으로 build/probe하는 모델.

- **Acero**: 3-phase build (Partition → Per-partition build → Merge), 6개 task group 기반 스케줄링. Partition 경계 기준으로 lock-free parallel build.
- **Polars**: 3-stage build (partition counting → scatter → per-partition hash map build). Rayon `par_iter` 기반. `SyncPtr`로 lock-free scatter.
- **DataFusion (Partitioned)**: `RepartitionExec`로 양쪽 데이터를 hash partitioning. 각 partition이 독립적으로 build → probe (lock-free).

### Pattern D: Adaptive Selection

**대표 엔진**: ClickHouse

30+ hash table variants에서 키 타입/크기에 따라 최적 variant를 자동 선택. 동시에 3가지 join 전략 (HashJoin/ConcurrentHashJoin/GraceHashJoin) 중 상황에 맞는 것을 선택.

- `chooseMethod()`: 키 타입 분석 → FixedHashMap / HashMap / HashMapWithSavedHash 등 선택
- `ConcurrentHashJoin` vs `GraceHashJoin`: 메모리 상황과 병렬도에 따라 선택

### Pattern E: GPU Massive Parallelism

**대표 엔진**: RAPIDS cuDF

수만~수십만 GPU thread가 동시에 단일 hash table을 build/probe하는 모델. CPU와 근본적으로 다른 접근.

- **Build**: 1 thread = 1 row insertion, atomic CAS 기반 lock-free
- **Probe**: Cooperative Group (2 threads) = 1 probe row, double hashing
- **No Partitioning**: GPU의 massive parallelism이 memory latency를 hide하므로 partitioning 불필요
- **2-Pass**: size estimation → result retrieval (GPU에서 dynamic allocation이 비효율적이므로)

### 병렬성 모델 비교 요약

| 패턴 | 대표 엔진 | Build 병렬화 | Probe 병렬화 | 핵심 동기화 |
|------|----------|------------|------------|-----------|
| Morsel-driven | DuckDB, Umbra | Thread-local → CAS merge | Morsel 단위 독립 | Barrier + CAS |
| Build-merge | Velox, ClickHouse | Per-driver → merge | Shared HT read-only | Barrier + last-driver merge |
| Partition-based | Acero, Polars, DataFusion | Per-partition 독립 | Per-partition 독립 | Lock-free (파티션 분리) |
| Adaptive | ClickHouse | 상황별 선택 | 상황별 선택 | 다양 |
| GPU massive | cuDF | Atomic CAS | Cooperative Groups | GPU atomics |

---

## 5. Memory Management / Spill 전략 비교

| 엔진 | Spill-to-Disk | 핵심 전략 |
|------|-------------|----------|
| **DuckDB** | O (External Hash Join) | Radix partitioning → 파티션 단위 build/probe 순환, dynamic repartitioning |
| **Velox** | O (Memory Arbitration) | Hash bit range partitioning → recursive spilling, memory arbitrator 통합 |
| **ClickHouse** | O (Grace Hash Join) | 동적 rehash (버킷 수 2배 증가), FileBucket 기반 디스크 저장 |
| **DataFusion** | X | `MemoryReservation.try_grow()` 실패 시 에러 반환 |
| **Acero** | X | 전체 build 데이터가 메모리에 상주해야 함 |
| **cuDF** | X | GPU VRAM 내에서만 동작, RMM pool allocator로 부분 완화 |
| **Polars** | X | In-memory 엔진, OOM 시 실패 |
| **Umbra** | O (Buffer Manager) | Variable-size page + SSD 투명 활용, pointer swizzling |

### Spill 지원 엔진의 설계 비교

- **DuckDB**: `RadixPartitionedTupleData` 기반. 초기 16개 파티션(4 radix bits)에서 시작, 메모리 초과 시 radix bits 증가하여 재분배. Load factor도 2.0→1.5로 축소.
- **Velox**: `HashBitRange` 기반. Memory arbitrator가 operator를 spill 대상으로 선택. Recursive spilling 지원 (bit range offset 이동).
- **ClickHouse**: Grace Hash Join. Bucket 0은 in-memory, 나머지는 디스크. 동적으로 버킷 수를 2배로 rehash. `try_to_lock` + random order flush로 contention 감소.

---

## 6. Join Types 지원 매트릭스

| Join Type | DuckDB | Velox | ClickHouse | DataFusion | Acero | cuDF | Polars | Umbra |
|-----------|--------|-------|------------|------------|-------|------|--------|-------|
| **Inner** | O | O | O | O | O | O | O | O |
| **Left (Outer)** | O | O | O | O | O | O | O | O |
| **Right (Outer)** | O | O | O | O | O | - | O | - |
| **Full Outer** | O | O | O | O | O | O | O | - |
| **Left Semi** | O | O | O | O | O | O | O | O |
| **Left Anti** | O | O | O | O | O | O | O | O |
| **Right Semi** | O | O | O | O | O | - | - | - |
| **Right Anti** | O | - | O | O | O | - | - | - |
| **Mark** | O | O (Project) | - | O | - | - | - | - |
| **Single** | O | - | - | - | - | - | - | - |
| **ASOF** | - | - | O | - | - | - | O | - |
| **Cross** | - | - | O | - | - | - | O | - |
| **Conditional** | - | - | - | - | - | O | - | - |
| **WCOJ** | - | - | - | - | - | - | - | O |

> 주: "-"는 해당 hash join 코드에서 직접 지원하지 않음을 의미. 별도 operator로 지원할 수 있음.

---

## 7. GPU vs CPU 구조적 차이

| 관점 | CPU Hash Join | GPU Hash Join (cuDF) |
|------|-------------|---------------------|
| **Hash Table** | Custom (salt/tag/stamp 기반), per-thread 또는 partitioned | cuco lock-free open addressing, single global table |
| **Partitioning** | Radix partitioning으로 cache-friendly 접근 (DuckDB, Acero) | 없음 — massive parallelism이 latency를 hide |
| **Build 병렬성** | 수~수십 thread, partition별 독립 또는 CAS | 수만 thread, 1 thread = 1 row, atomic CAS |
| **Probe 병렬성** | Morsel/partition 단위 | 1 CG (2 threads) = 1 probe row |
| **Memory 계층** | L1/L2/L3 cache 활용이 핵심 | GPU VRAM bandwidth (수백 GB/s) + shared memory |
| **출력 크기 결정** | Dynamic growth (vector append) | 2-pass: size estimation → exact allocation |
| **Spill** | 지원 (Grace/External) | 미지원 — VRAM 한계 |
| **Hash 충돌** | Linear probing + salt/tag | Double hashing + cooperative groups |
| **Warp 활용** | N/A | Conditional join: warp별 shared memory output cache, `__ballot_sync` 동기화 |

### GPU 최적화의 핵심

1. **Partitioning이 불필요한 이유**: CPU에서 radix partitioning의 목적은 cache miss 감소. GPU에서는 (1) 수천 개 active thread가 memory latency를 hide, (2) 수백 GB/s bandwidth, (3) warp divergent access도 hardware가 효율적으로 처리
2. **2-Pass의 필요성**: GPU kernel 실행 중 dynamic memory allocation이 비효율적. Size estimation pass로 정확한 output buffer를 한 번에 할당
3. **Cooperative Groups**: 2-thread CG가 2-slot bucket의 각 slot을 동시 검사. 32-thread warp에서 16개 CG가 16개 probe row를 병렬 처리

---

## 8. 핵심 설계 패턴 및 트렌드

### 8.1 Tag/Salt/Stamp를 통한 Early Filtering의 보편화

거의 모든 엔진이 hash 값의 일부를 별도로 저장하여 key 비교 전 빠른 필터링을 수행한다. 이는 hash join에서 가장 빈번한 경우인 "매칭이 없는 경우"를 최적화하는 핵심 기법이다:
- DuckDB: 16-bit salt in `ht_entry_t`
- Velox: 7-bit tag in SIMD-friendly bucket
- Acero: 7-bit stamp in Swiss Table block
- Umbra: 4-bit Bloom filter in pointer upper bits

### 8.2 SIMD 활용의 확대

- **Velox**: 16-way SIMD tag 비교 (SSE2/NEON), 4-way interleaved probing
- **Acero**: AVX2 가속 `early_filter_imp_avx2_x8/x32`
- **Polars/DataFusion**: hashbrown의 Swiss Table이 내부적으로 SIMD 활용

### 8.3 Partition-then-Build 패턴

대부분의 엔진이 build phase를 "데이터 수집 → partitioning → per-partition hash table 구축"의 3단계로 구성:
- **Acero**: Partition → Build per-partition → Merge
- **Polars**: Count → Scatter → Build per-partition
- **DuckDB**: Thread-local sink → Combine → Parallel finalize

### 8.4 Lock-Free Concurrent Insert

Build phase의 병렬 삽입에서 lock 대신 CAS 기반 lock-free 방식이 표준화:
- DuckDB: `InsertRowToEntry<PARALLEL>` — `compare_exchange_strong/weak`
- Velox: Partition-based parallel insert (partition 범위 내만 접근)
- ClickHouse: TwoLevelHashMap bucket-level ownership
- cuDF: GPU atomic CAS

### 8.5 Bloom Filter 기반 Probe 최적화

- **DuckDB**: Build 측에서 Bloom filter 구축, probe 측 스캔 시 pushdown
- **Acero**: `BlockedBloomFilter` — 57-bit mask, fold 메커니즘, Bloom filter pushdown을 하위 join 노드로 전파
- **Umbra**: Register-blocked Bloom filter 기반 semi-join reducer

### 8.6 Adaptive/Hybrid 전략의 부상

단일 알고리즘이 모든 워크로드에 최적이 아니므로, 데이터 특성에 따른 적응형 전략이 증가:
- **ClickHouse**: 30+ hash table variants 자동 선택
- **Velox**: kHash/kArray/kNormalizedKey 자동 전환
- **DataFusion**: CollectLeft/Partitioned/Auto 모드
- **DuckDB**: PerfectHashJoin 자동 전환, skew 감지

### 8.7 Radix Partitioning의 재평가

Umbra/TUM의 실험 [Bandle et al., SIGMOD 2021]에서 radix join이 실제 시스템에서 기대만큼의 이점을 보이지 않았다는 결론은 주목할 만하다. TPC-H 59개 join 중 1개만 개선. 대신 Bloom filter와 SIMD 기반 early filtering이 더 실용적인 최적화로 자리잡고 있다.

---

## 9. 참고 문헌 통합 목록

### 학술 논문

| # | 논문 | 저자 | 학회/연도 | 관련 엔진 |
|---|------|------|---------|----------|
| 1 | "Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age" | Viktor Leis, Peter Boncz, Alfons Kemper, Thomas Neumann | SIGMOD 2014 | DuckDB, Umbra/HyPer |
| 2 | "Efficiently Compiling Efficient Query Plans for Modern Hardware" | Thomas Neumann | VLDB 2011 | Umbra/HyPer |
| 3 | "Umbra: A Disk-Based System with In-Memory Performance" | Thomas Neumann, Michael J. Freitag | CIDR 2020 | Umbra |
| 4 | "Tidy Tuples and Flying Start: Fast Compilation and Fast Execution of Relational Queries in Umbra" | Timo Kersten, Viktor Leis, Thomas Neumann | VLDB Journal 2021 | Umbra |
| 5 | "Adopting Worst-Case Optimal Joins in Relational Database Systems" | Michael Freitag et al. | VLDB 2020 | Umbra |
| 6 | "To Partition, or Not to Partition, That is the Join Question in a Real System" | Maximilian Bandle, Jana Giceva, Thomas Neumann | SIGMOD 2021 | Umbra |
| 7 | "Simple, Efficient, and Robust Hash Tables for Join Processing" | Altan Birler, Tobias Schmidt, Philipp Fent, Thomas Neumann | DaMoN 2024 | Umbra/CedarDB |
| 8 | "Robust Join Processing with Diamond Hardened Joins" | Altan Birler, Alfons Kemper, Thomas Neumann | VLDB 2024 | Umbra/CedarDB |
| 9 | "Saving Private Hash Join: How to Implement an External Hash Join within Limited Memory" | Kuiper et al. | VLDB 2024 | DuckDB |
| 10 | "Velox: Meta's Unified Execution Engine" | Pedro Pedreira et al. | VLDB 2022 | Velox |
| 11 | "Apache Arrow DataFusion: A Fast, Embeddable, Modular Analytic Query Engine" | Lamb et al. | SIGMOD 2024 | DataFusion |
| 12 | "Triton Join: Efficiently Scaling to a Large Join State on GPUs with Fast Interconnects" | Lutz et al. | SIGMOD 2022 | cuDF |
| 13 | "Concurrent Hash Tables: Fast and General(?!)" | Tobias Maier, Peter Sanders, Roman Dementiev | PPoPP 2016 / TOPC 2019 | Umbra |
| 14 | "Balancing vectorized query execution with bandwidth-optimized storage" | Peter Boncz | Ph.D. Thesis 2002 | DataFusion |

### 소스 코드 저장소

| 엔진 | Repository |
|------|-----------|
| DuckDB | https://github.com/duckdb/duckdb |
| Velox | https://github.com/facebookincubator/velox |
| ClickHouse | https://github.com/ClickHouse/ClickHouse |
| DataFusion | https://github.com/apache/datafusion |
| Arrow (Acero) | https://github.com/apache/arrow |
| cuDF | https://github.com/rapidsai/cudf |
| Polars | https://github.com/pola-rs/polars |
| cuCollections | https://github.com/NVIDIA/cuCollections |

### 블로그/기타 자료

- CedarDB Blog: "Simple, Efficient, and Robust Hash Tables" — https://cedardb.com/blog/simple_efficient_hash_tables/
- Abseil Swiss Table: https://abseil.io/about/design/swisstables
- F14 Hash Table (Facebook): Velox의 tag 기반 bucket 구조의 영감
