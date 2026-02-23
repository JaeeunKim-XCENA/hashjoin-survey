# RAPIDS cuDF — GPU Hash Join Partitioning 전략 심층 분석

## 요약

RAPIDS cuDF의 GPU hash join은 **명시적인 데이터 partitioning을 수행하지 않는다**. 학술적 radix join(Boncz et al., 1999)이 cache/TLB 최적화를 위해 multi-pass partitioning을 수행하는 것과 달리, cuDF는 **단일 global hash table**에 대해 수천~수만 개의 GPU thread가 동시에 접근하는 방식을 채택한다. 참고로 DuckDB도 in-memory join에서는 partitioning을 활용하지 않고 `Unpartition()`으로 단일 hash table을 구축하며, radix partitioning은 오직 external hash join(메모리 부족 시 spill-to-disk)을 위한 메커니즘이다.

이 설계의 핵심 근거:
- GPU의 **대규모 thread-level parallelism (TLP)** 이 memory latency를 hide함
- GPU global memory의 **높은 bandwidth** (수백 GB/s)가 random access 패턴을 상쇄함
- cuCollections (cuco) 라이브러리의 **lock-free open addressing** hash table이 concurrent access에 최적화되어 있음
- **Cooperative Groups**를 통한 bucket 단위 병렬 검사로 memory access 효율을 극대화함

cuDF에서 "partitioning"이 존재하는 유일한 맥락은 `cudf::hash_partition()` API인데, 이는 join 내부 메커니즘이 아닌 **사용자 수준의 테이블 재배치 유틸리티**이며, hash join 실행 경로에서는 호출되지 않는다.

---

## 1. GPU Partitioning 개요: GPU 아키텍처와 Partitioning의 관계

### 1.1 CPU에서 Partitioning이 사용되는 맥락

CPU hash join에서 radix partitioning은 두 가지 서로 다른 목적으로 사용된다:

**학술적 radix join (Boncz et al., ICDE 1999)** — **cache/TLB 최적화** 목적. Multi-pass partitioning으로 build/probe 양쪽을 cache-sized 단위로 분할하여 hash table build와 probe가 전부 L1/L2 cache 안에서 이루어지게 한다.

**DuckDB의 radix partitioning** — **메모리 관리 (grace hash join)** 목적. `INITIAL_RADIX_BITS = 4`로 16개 파티션에 streaming append하지만, **in-memory join에서는 `Unpartition()`으로 전부 합쳐서 단일 hash table을 구축**하므로 partitioning이 사실상 의미 없다. 메모리가 부족한 external join에서만 파티션 단위로 spill/reload하는 grace hash join으로서 기능한다. Cache locality는 vectorized execution(2048-tuple batch)으로 별도 확보한다.

### 1.2 GPU에서 Partitioning이 불필요한 이유

GPU 아키텍처는 CPU와 근본적으로 다른 메커니즘으로 memory latency를 처리한다:

**Thread-Level Parallelism (TLP)에 의한 Latency Hiding:**
- GPU는 SM(Streaming Multiprocessor)당 수천 개의 active thread를 동시에 유지한다
- 하나의 warp(32 threads)이 memory access로 stall하면, hardware scheduler가 즉시 다른 warp으로 전환한다
- 이를 통해 global memory의 수백 cycle latency가 다른 warp의 연산으로 "숨겨진다"

**High Memory Bandwidth:**
- GPU global memory bandwidth는 수백 GB/s ~ 1 TB/s 이상 (예: A100 2TB/s, H100 3.35 TB/s HBM3)
- CPU의 main memory bandwidth (수십 GB/s)에 비해 10배 이상 높다
- Random access 패턴이라 해도 GPU의 높은 bandwidth가 총 throughput을 보장한다

**Hardware-Managed Divergent Access:**
- GPU memory controller가 warp 내 thread들의 divergent memory access를 coalescing 또는 분리 처리
- Explicit partitioning 없이도 hardware가 memory access pattern을 최적화

이러한 이유로 cuDF의 hash join은 radix partitioning을 수행하지 않고, **단일 global hash table + massive parallelism** 전략을 사용한다. 이는 학술적 radix join이 cache locality를 위해 partitioning을 필수로 하는 것과 대비되며, DuckDB처럼 in-memory join에서 단일 hash table을 사용하는 접근과는 오히려 유사한 면이 있다(다만 DuckDB는 external join 시 partitioning을 활용하고, cuDF는 spill 자체를 지원하지 않는다는 차이가 있다).

### 1.3 소스 코드에서의 확인

cuDF hash join 코드(`cpp/src/join/hash_join.cu`)에는 partitioning 관련 로직이 전혀 존재하지 않는다. Build phase에서 `hash_table.insert()`를 호출하면 cuco 내부의 CUDA kernel이 모든 build row를 하나의 global hash table에 삽입하고, probe phase에서 `hash_table.retrieve()`가 모든 probe row에 대해 같은 global hash table을 동시에 probing한다.

```cpp
// cpp/src/join/hash_join.cu:149-161 — Build phase: partitioning 없이 전체 삽입
auto insert_rows = [&](auto const& build, auto const& d_hasher) {
    auto const iter = cudf::detail::make_counting_transform_iterator(0, pair_fn{d_hasher});
    if (nulls_equal == cudf::null_equality::EQUAL or not nullable(build)) {
        hash_table.insert(iter, iter + build.num_rows(), stream.value());
    } else {
        auto const stencil = thrust::counting_iterator<size_type>{0};
        auto const pred    = row_is_valid{bitmask};
        hash_table.insert_if(iter, iter + build.num_rows(), stencil, pred, stream.value());
    }
};
```

---

## 2. Hash Partitioning Kernel: GPU에서의 Hash 기반 데이터 분배

### 2.1 cudf::hash_partition() — Join과 독립적인 유틸리티

cuDF는 `cudf::hash_partition()` API를 제공하지만(`cpp/include/cudf/partitioning.hpp:97-104`), 이는 **hash join 내부에서 사용되지 않는** 별도의 유틸리티 함수이다:

```cpp
// cpp/include/cudf/partitioning.hpp:97-104
std::pair<std::unique_ptr<table>, std::vector<size_type>> hash_partition(
  table_view const& input,
  std::vector<size_type> const& columns_to_hash,
  int num_partitions,
  hash_id hash_function = hash_id::HASH_MURMUR3,
  uint32_t seed = DEFAULT_HASH_SEED,
  rmm::cuda_stream_view stream = cudf::get_default_stream(),
  rmm::device_async_resource_ref mr = cudf::get_current_device_resource_ref());
```

이 API는 사용자가 직접 테이블을 hash 기반으로 재배치하고 싶을 때(예: multi-GPU 환경에서의 데이터 분산) 사용하는 것이지, join 연산 시 내부적으로 호출되지 않는다. `cpp/src/join/` 디렉토리 내 어떤 파일에서도 `hash_partition`을 호출하지 않는다.

### 2.2 cuco 내부의 Hash 기반 Slot 분배

cuco의 open addressing hash table에서 데이터의 "분배"는 hash function에 의해 결정된다. cuDF hash join의 hash table은 다음과 같이 구성된다:

**Hash Join (cuco::static_multiset):**
- **Double hashing** probing scheme (`cuco::double_hashing<2, hasher1, hasher2>`, `cpp/include/cudf/detail/join/hash_join.cuh:85`)
- `hasher1`: row hash 값을 그대로 사용하여 초기 slot 결정 (`cpp/include/cudf/detail/join/hash_join.cuh:59-65`)
- `hasher2`: row hash 값에 MurmurHash3를 추가 적용하여 step size 결정 (`cpp/include/cudf/detail/join/hash_join.cuh:67-78`)
- **Bucket size = 2** (`cuco::storage<2>`): 인접한 2개 slot이 하나의 bucket을 형성

**Distinct Hash Join (cuco::static_set):**
- **Linear probing** with CG size 1 (`cuco::linear_probing<1, hasher>`, `cpp/include/cudf/detail/join/distinct_hash_join.cuh:147`)
- Bucket size = 1 (`cuco::storage<1>`)

**Filtered Join (cuco::bucket_storage):**
- 직접 `cuco::bucket_storage`와 `cuco::static_set_ref`를 사용 (`cpp/include/cudf/detail/join/filtered_join.cuh:165-169`)
- Bucket size = 1, 다양한 probing scheme (primitive: CG=1, nested: CG=4, simple: CG=1)

이 slot-level 분배는 학술적 radix join의 partition-level 분배와 근본적으로 다르다. 학술적 radix join은 데이터를 물리적으로 재배치(scatter)하여 partition별 cache locality를 확보하지만, GPU는 hash function에 의한 implicit한 slot 분배만 수행하고 물리적 데이터 재배치는 하지 않는다. DuckDB도 in-memory join에서는 물리적 재배치 없이 단일 hash table을 사용한다는 점에서, partitioning 없는 접근 자체는 GPU만의 특성이 아니다.

---

## 3. Build Phase의 GPU Partitioning

### 3.1 단일 Global Hash Table에 Concurrent Insert

cuDF의 build phase(`cpp/src/join/hash_join.cu:136-176`)는 partitioning 없이 모든 build row를 하나의 global hash table에 삽입한다.

**Build 과정:**
1. 각 build row에 대해 `pair_fn{d_hasher}` functor가 `(hash_value, row_index)` pair를 생성 (`cpp/src/join/join_common_utils.cuh:23-33`)
2. `hash_table.insert(iter, iter + build.num_rows(), stream.value())`로 전체 삽입
3. cuco 내부에서 CUDA kernel이 launch되어 각 thread가 하나의 row를 담당

**GPU Thread-to-Row 매핑 (Build):**
- 1 GPU thread <-> 1 build row insertion
- Thread가 row의 hash value를 계산하고, double hashing으로 결정된 slot에 atomic CAS(Compare-And-Swap)를 수행
- CAS 실패 시(다른 thread가 먼저 점유) probing sequence의 다음 slot으로 이동
- `always_not_equal` comparator (`cpp/include/cudf/detail/join/hash_join.cuh:49-57`)로 인해 multiset에서는 모든 insert가 성공할 때까지 probing

**Hash Table 크기 결정:**
- Load factor 0.5 (`CUCO_DESIRED_LOAD_FACTOR`, `cpp/include/cudf/detail/cuco_helpers.hpp:16`)
- Hash table capacity = `build.num_rows() / 0.5 = build.num_rows() * 2`
- `cuco::extent{static_cast<size_t>(build.num_rows())}` + load_factor로 생성 시 크기 결정 (`cpp/src/join/hash_join.cu:535-536`)

### 3.2 Hash Table의 메모리 레이아웃

cuco의 open addressing hash table은 **contiguous array**로 할당된다:
- `cuco::storage<2>`의 경우 인접한 2개 slot이 하나의 bucket을 구성
- Bucket은 메모리 상 연속적이므로 하나의 memory transaction으로 2개 slot을 읽을 수 있음
- 이는 GPU의 memory coalescing과 잘 맞물림: 연속적인 thread들이 연속적인 bucket에 접근할 때 coalesced access가 가능

### 3.3 Null 처리와 Bitmask

Build 시 nullable column이 있으면 `bitmask_and()`로 row 단위 validity mask를 생성한 후, `insert_if()`로 유효한 row만 삽입한다:

```cpp
// cpp/src/join/hash_join.cu:154-159
auto const stencil = thrust::counting_iterator<size_type>{0};
auto const pred    = row_is_valid{bitmask};
hash_table.insert_if(iter, iter + build.num_rows(), stencil, pred, stream.value());
```

`row_is_valid` functor (`cpp/src/join/join_common_utils.cuh:38-49`)는 bitmask의 해당 bit를 검사하여 null row의 삽입을 방지한다.

---

## 4. Probe Phase의 GPU Partitioning

### 4.1 Two-Pass Approach: Partitioning 대신 정확한 크기 사전 계산

CPU hash join에서 partitioning의 또 다른 이점은 파티션별로 output buffer를 관리할 수 있다는 점이다. GPU에서는 kernel 실행 중 dynamic memory allocation이 비효율적이므로, cuDF는 **2-pass 방식**으로 이 문제를 해결한다:

**Pass 1 — Size Estimation** (`compute_join_output_size`, `cpp/src/join/hash_join.cu:199-265`):
```cpp
auto compute_size = [&](auto equality, auto d_hasher) {
    auto const iter = cudf::detail::make_counting_transform_iterator(0, pair_fn{d_hasher});
    if (join == join_kind::LEFT_JOIN) {
        return hash_table.count_outer(
            iter, iter + probe_table_num_rows, equality, hash_table.hash_function(), stream.value());
    } else {
        return hash_table.count(
            iter, iter + probe_table_num_rows, equality, hash_table.hash_function(), stream.value());
    }
};
```

- cuco의 `count()` / `count_outer()` API가 내부적으로 CUDA kernel을 launch
- 각 probe row에 대해 매칭되는 build row의 수를 계산
- 전체 결과 크기를 반환하여 output buffer를 정확한 크기로 한 번에 할당

**Pass 2 — Result Retrieval** (`probe_join_hash_table`, `cpp/src/join/hash_join.cu:288-390`):
```cpp
auto retrieve_results = [&](auto equality, auto iter) {
    if (join == join_kind::FULL_JOIN || join == join_kind::LEFT_JOIN) {
        hash_table.retrieve_outer(iter, iter + probe_table_num_rows,
                                  equality, hash_table.hash_function(),
                                  out_probe_begin, out_build_begin, stream.value());
    } else {
        hash_table.retrieve(iter, iter + probe_table_num_rows,
                            equality, hash_table.hash_function(),
                            out_probe_begin, out_build_begin, stream.value());
    }
};
```

- 사전 할당된 `left_indices`, `right_indices` device vector에 결과를 기록
- `cudf::prefetch::detail::prefetch()`로 output buffer의 GPU memory prefetching 수행 (`cpp/src/join/hash_join.cu:325-326`)

### 4.2 Cooperative Groups를 통한 Probe 효율화

Hash join의 probe는 **Cooperative Group (CG) size = 2** (`DEFAULT_JOIN_CG_SIZE`, `cpp/include/cudf/detail/join/join.hpp:12`)를 사용한다:

- 2개의 thread가 하나의 cooperative group을 형성하여 1개의 probe row를 담당
- Bucket size = 2이므로, CG 내 2 threads가 동시에 bucket의 2 slots를 각각 검사
- 하나의 memory transaction으로 bucket을 읽고 2 slots를 병렬 비교 → memory access 횟수 절반
- 32-thread warp 내에서 16개의 CG가 동시에 16개의 probe row를 처리

이 CG 기반 probing은 "partitioning 없이도 효율적인 probe"를 가능하게 하는 핵심 메커니즘이다. 학술적 radix join에서는 cache locality를 위해 partitioning이 필수적이지만, GPU에서는 CG + bucket probing + massive TLP로 memory access efficiency를 확보한다.

### 4.3 Equality Check 계층

Probe 시 매칭은 2단계로 이루어진다 (`pair_equal`, `cpp/src/join/hash_join.cu:77-95`):

1. **Hash value 비교**: `lhs.first == rhs.first` — 저렴한 integer comparison
2. **실제 row equality check**: hash가 같을 때만 수행 — 비싼 multi-column comparison

```cpp
__device__ __forceinline__ bool operator()(
    cuco::pair<hash_value_type, size_type> const& lhs,
    cuco::pair<hash_value_type, size_type> const& rhs) const noexcept
{
    return lhs.first == rhs.first and
           _check_row_equality(lhs_index_type{lhs.second}, rhs_index_type{rhs.second});
}
```

Hash value를 `(hash_value, row_index)` pair의 첫 번째 요소로 저장하여, 실제 row data에 접근하기 전에 저렴하게 false positive를 걸러낸다.

### 4.4 Mixed Join의 Precomputed Probe Indices

Mixed join(`cpp/src/join/mixed_join.cu:90-162`)은 cuco의 register spilling 문제를 우회하기 위해 probe indices를 사전 계산한다. 이는 일종의 "probe preparation pass"로, partitioning과는 목적이 다르지만 multi-pass 접근이라는 점에서 유사한 구조를 가진다:

```cpp
// cpp/src/join/mixed_join.cu:130-151 — precompute_mixed_join_data
auto precompute_fn = [=] __device__(size_type i) {
    auto const probe_key = cuco::pair<hash_value_type, size_type>{hash_probe(i), i};
    auto const hash1_val = cuda::std::get<0>(probe_hash_fn)(probe_key);
    auto const hash2_val = cuda::std::get<1>(probe_hash_fn)(probe_key);
    auto const init_idx = static_cast<hash_value_type>(
        (static_cast<std::size_t>(hash1_val) % num_buckets) * bucket_size);
    auto const step_val = static_cast<hash_value_type>(
        ((static_cast<std::size_t>(hash2_val) % num_buckets_minus_one) + 1) * bucket_size);
    return cuda::std::pair{probe_key, cuda::std::pair{init_idx, step_val}};
};
```

이 precomputation은 (initial_slot, step_size) pair를 미리 계산하여 device vector에 저장한 후, 이후 count/retrieve kernel에서 재사용한다. 이를 통해 cuco의 double hashing probing logic을 cudf가 직접 재구현(`hash_table_prober`, `cpp/src/join/mixed_join_common_utils.cuh:208-249`)하여 register pressure를 줄이고 약 **20% 성능 향상**을 달성한다.

---

## 5. CPU Hash Join과의 구조적 차이

### 5.1 Partitioning 전략 비교

| 관점 | CPU — Classic Radix Join (학술적) | CPU — DuckDB | GPU (cuDF) |
|------|----------------------------------|-------------|------------|
| **Partitioning 여부** | Multi-pass radix partitioning | In-memory: `Unpartition()` → 단일 HT / External: radix partitioning | Partitioning 없음 — 단일 global hash table |
| **Partitioning 목적** | Cache/TLB locality 최적화 | 메모리 관리 (grace hash join) | 해당 없음 |
| **Hash Table 구조** | 파티션별 독립 hash table | In-memory: 단일 HT / External: 파티션별 독립 HT | 전체 build data에 대한 단일 cuco::static_multiset |
| **Memory Latency 대응** | Partitioning → cache hit 증가 | Vectorized execution (2048-tuple batch) | Massive TLP → latency hiding |
| **Output Buffer 관리** | 파티션 단위 관리 | Dynamic growth (vector append) | 2-pass: size estimation → exact allocation |
| **Spill-to-Disk** | N/A (in-memory 전용) | Grace Hash Join (동적 repartitioning) | 미지원 — GPU memory 내에서만 동작 |

### 5.2 Latency Hiding 메커니즘 비교

**CPU (DuckDB):**
- Cache hierarchy (L1: ~1ns, L2: ~4ns, L3: ~10ns, Main memory: ~100ns)
- Cache miss 시 100ns 이상의 penalty가 발생하나, DuckDB는 partitioning이 아닌 **vectorized execution (2048-tuple batch)** 으로 cache locality를 확보
- In-memory join에서는 단일 hash table을 사용하므로 cache miss는 batch 처리로 amortize
- Out-of-order execution, prefetching 등으로 일부 latency hiding 가능하나 제한적
- Thread 수: 수~수십 개 → latency hiding 능력 제한적

**GPU (cuDF):**
- GPU global memory latency: ~400-600 cycles
- 하지만 SM당 수천 개의 active thread가 대기 중이므로, memory stall 시 즉시 다른 warp으로 switching
- Warp scheduler가 hardware 수준에서 zero-overhead context switch 수행
- Thread 수: 수만~수십만 개 → latency 완전 hiding 가능

### 5.3 "Partitioning" 개념의 GPU 재해석

GPU hash join에서 "partitioning"에 해당하는 개념이 완전히 없는 것은 아니다. 다만 그 형태가 CPU와 근본적으로 다르다:

1. **Hash function에 의한 implicit slot 분배**: cuco의 double hashing이 build row들을 hash table 전체에 고르게 분배한다. Load factor 0.5는 slot의 50% 점유를 보장하여 probing chain이 짧게 유지된다.

2. **Cooperative Group에 의한 bucket 단위 처리**: CG size = 2로 2 threads가 하나의 2-slot bucket을 처리하는 것은, 데이터를 bucket 크기 단위로 "micro-partitioning"하는 것과 유사한 효과를 가진다.

3. **2-pass probe의 size estimation**: CPU의 partitioning이 output buffer를 파티션 단위로 관리하는 것에 대응하여, GPU는 전체 output 크기를 먼저 계산하여 한 번에 할당한다.

---

## 6. DuckDB와의 비교 (간략)

| 항목 | DuckDB | cuDF |
|------|--------|------|
| **In-memory Partition** | 없음 — `Unpartition()`으로 단일 hash table 구축 | 없음 — 단일 global hash table |
| **External Partition** | Radix partitioning (상위 bit 기반, 초기 16개 → repartition) | 해당 없음 (spill 미지원) |
| **Repartitioning** | 메모리 부족 시 radix bits 증가 (최대 12 bits, 4096 partitions) | 해당 없음 |
| **Hash Table** | Custom chaining (pointer collision chain) | cuco::static_multiset (open addressing, double hashing) |
| **Build 병렬성** | Thread-local HT → merge (in-memory) / 파티션별 독립 build (external) | Atomic CAS 기반 concurrent insert into single hash table |
| **Probe 병렬성** | Morsel 단위 병렬 probe (in-memory) / 파티션별 독립 probe (external) | 수천 thread가 동시에 같은 hash table probe |
| **Cache Locality** | Vectorized execution (2048-tuple batch) | Massive TLP로 latency hiding (cache locality 불필요) |
| **Out-of-Memory 처리** | Grace Hash Join (spill-to-disk) | 미지원 — GPU memory에 fit해야 함 |
| **구현 복잡도** | Partitioning + spill + repartitioning 로직 복잡 | 단순 — cuco API에 위임, partitioning 로직 불필요 |

핵심 차이: DuckDB와 cuDF 모두 **in-memory join에서는 단일 hash table**을 사용한다는 점에서 유사하다. 차이는 메모리 초과 시의 대응에 있다: DuckDB는 radix partitioning 기반의 grace hash join으로 spill-to-disk를 지원하지만, cuDF는 spill을 지원하지 않으며 GPU memory에 fit해야 한다. DuckDB의 radix partitioning은 cache locality가 아닌 **메모리 관리 (계층적 repartitioning의 용이성)** 를 위한 것이다.

---

## 7. Key References

### 소스 코드 (RAPIDS cuDF)

| 파일 | 주요 함수/클래스 | 역할 |
|------|----------------|------|
| `cpp/src/join/hash_join.cu` | `build_hash_join()`, `compute_join_output_size()`, `probe_join_hash_table()` | Build: partitioning 없이 전체 insert. Probe: 2-pass (size estimation + retrieval) |
| `cpp/include/cudf/detail/join/hash_join.cuh` | `hash_table_t` (cuco::static_multiset) | Hash table 타입 정의: double hashing, CG=2, bucket_size=2 |
| `cpp/include/cudf/detail/join/join.hpp` | `DEFAULT_JOIN_CG_SIZE = 2` | Cooperative Group size 상수 |
| `cpp/include/cudf/detail/cuco_helpers.hpp` | `CUCO_DESIRED_LOAD_FACTOR = 0.5` | Hash table load factor — 50% 점유율로 probing chain 최소화 |
| `cpp/src/join/join.cu` | `detail::inner_join()` | Inner join 시 작은 테이블을 build side로 자동 선택 |
| `cpp/src/join/mixed_join.cu` | `precompute_mixed_join_data()` | Mixed join: double hashing indices 사전 계산 (register spilling 우회) |
| `cpp/src/join/mixed_join_common_utils.cuh` | `hash_table_prober`, `hash_probe_result` | Mixed join의 직접 구현된 probing logic: bucket 단위 slot 검사 |
| `cpp/src/join/conditional_join_kernels.cuh` | `conditional_join<>` kernel, `add_pair_to_cache()`, `flush_output_cache()` | Warp-level shared memory output caching (non-hash nested loop join) |
| `cpp/src/join/filtered_join.cu` | `insert_build_table()`, `query_build_table()` | cuco::detail::open_addressing_ns kernel 직접 호출 (insert_if_n, contains_if_n) |
| `cpp/include/cudf/detail/join/filtered_join.cuh` | `filtered_join`, `storage_type` (cuco::bucket_storage) | Semi/anti join: bucket_storage 기반 hash set |
| `cpp/include/cudf/detail/join/distinct_hash_join.cuh` | `distinct_hash_join`, `hash_table_type` (cuco::static_set) | Distinct join: linear probing, CG=1, bucket_size=1 |
| `cpp/include/cudf/partitioning.hpp` | `hash_partition()` | 사용자 수준 hash partitioning API — join 내부에서는 사용되지 않음 |
| `cpp/src/join/join_common_utils.cuh` | `pair_fn`, `row_is_valid` | Hash pair 생성, null validity check 유틸리티 |
| `cpp/src/join/join_common_utils.hpp` | `DEFAULT_JOIN_BLOCK_SIZE = 128` | Conditional/mixed join의 CUDA block size |

### 외부 참고 자료

- **cuCollections (cuco)**: https://github.com/NVIDIA/cuCollections — GPU-optimized concurrent hash table 라이브러리. cuDF의 hash join이 의존하는 static_multiset, static_set 등의 open addressing 구현 제공.
- **"Triton Join: Efficiently Scaling to a Large Join State on GPUs with Fast Interconnects"** (Lutz et al., SIGMOD 2022) — GPU hash join에서 데이터가 GPU memory를 초과할 때의 partitioned join 전략. cuDF의 현재 구현(single hash table, no partitioning, no spill)과 대비됨.
- **RMM (RAPIDS Memory Manager)**: https://github.com/rapidsai/rmm — cuDF의 GPU memory 관리 라이브러리. Pool allocator, managed memory 등 지원.
