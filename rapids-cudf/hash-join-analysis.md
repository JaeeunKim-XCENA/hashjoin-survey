# RAPIDS cuDF — GPU Hash Join 구현 분석

## 개요

RAPIDS cuDF는 NVIDIA에서 개발한 GPU 기반 DataFrame 라이브러리로, Apache Arrow 포맷을 기반으로 GPU 상에서 데이터 처리를 수행한다. Hash join 구현은 NVIDIA의 **cuCollections (cuco)** 라이브러리를 핵심 hash table로 사용하며, 모든 build/probe 연산이 CUDA kernel로 실행된다.

cuDF의 join 시스템은 크게 네 가지 경로로 구성된다:

1. **Hash Join** (`hash_join.cu`): 일반적인 equality hash join, `cuco::static_multiset` 기반
2. **Distinct Hash Join** (`distinct_hash_join.cu`): build 측 키가 unique한 경우의 최적화, `cuco::static_set` 기반
3. **Conditional Join** (`conditional_join.cu`): AST expression 기반의 비등가(non-equi) join
4. **Mixed Join** (`mixed_join.cu`): equality 조건 + expression 조건을 결합한 하이브리드 join

---

## 1. Hash Table 구조

### 1.1 cuco::static_multiset (Hash Join)

일반 hash join은 **`cuco::static_multiset`** 를 사용한다. 이는 duplicate key를 허용하는 GPU 전용 hash table이다.

```cpp
// cpp/include/cudf/detail/join/hash_join.cuh:80-87
using hash_table_t =
    cuco::static_multiset<cuco::pair<cudf::hash_value_type, cudf::size_type>,
                          cuco::extent<std::size_t>,
                          cuda::thread_scope_device,
                          always_not_equal,
                          cuco::double_hashing<DEFAULT_JOIN_CG_SIZE, hasher1, hasher2>,
                          rmm::mr::polymorphic_allocator<char>,
                          cuco::storage<2>>;
```

핵심 특성:
- **Open addressing** 방식: chaining 대신 slot 기반 probing
- **Double hashing** probing scheme: `hasher1`은 초기 slot 결정, `hasher2`는 step size 결정 (`cpp/include/cudf/detail/join/hash_join.cuh:59-78`)
- **Cooperative Group (CG) size = 2** (`DEFAULT_JOIN_CG_SIZE`, `cpp/include/cudf/detail/join/join.hpp:12`): 2개의 GPU thread가 협력하여 하나의 probing operation을 수행
- **Bucket size = 2** (`cuco::storage<2>`): 각 bucket에 2개 slot 저장
- **Key-value pair**: `cuco::pair<hash_value_type, size_type>` — (row hash, row index)
- **Empty sentinel**: `{std::numeric_limits<hash_value_type>::max(), cudf::JoinNoMatch}`
- **Insertion comparator**: `always_not_equal` — multiset이므로 insert 시 항상 중복 허용 (`cpp/include/cudf/detail/join/hash_join.cuh:49-57`)

### 1.2 cuco::static_set (Distinct Hash Join)

build 측 키가 unique한 경우 **`cuco::static_set`** 을 사용한다:

```cpp
// cpp/include/cudf/detail/join/distinct_hash_join.cuh:151-157
using hash_table_type = cuco::static_set<cuco::pair<hash_value_type, rhs_index_type>,
                                         cuco::extent<std::size_t>,
                                         cuda::thread_scope_device,
                                         always_not_equal,
                                         probing_scheme_type,
                                         rmm::mr::polymorphic_allocator<char>,
                                         cuco_storage_type>;
```

- **Linear probing** (`cuco::linear_probing<1, hasher>`, `cpp/include/cudf/detail/join/distinct_hash_join.cuh:147`): CG size 1로 single-thread probing
- **Bucket size = 1** (`cuco::storage<1>`)
- Distinct join은 키가 unique하므로 find 결과가 최대 1개 → set으로 충분

### 1.3 Mixed Join Multiset

Mixed join도 별도의 `cuco::static_multiset`를 사용한다:

```cpp
// cpp/src/join/mixed_join_common_utils.cuh:74-81
using mixed_multiset_type =
    cuco::static_multiset<pair_type,
                          cuco::extent<std::size_t>,
                          cuda::thread_scope_device,
                          mixed_join_always_not_equal,
                          cuco::double_hashing<1, mixed_join_hasher1, mixed_join_hasher2>,
                          rmm::mr::polymorphic_allocator<char>,
                          cuco::storage<2>>;
```

여기서는 CG size = 1이지만 bucket size = 2로, 단일 thread가 2-slot bucket을 probing한다.

### 1.4 Load Factor

모든 hash table은 기본 load factor **0.5** 를 사용한다 (`CUCO_DESIRED_LOAD_FACTOR`, `cpp/include/cudf/detail/cuco_helpers.hpp:16`). 즉, hash table 크기가 build 테이블 row 수의 약 2배가 되어 50% 점유율을 유지한다. 사용자가 load factor를 직접 지정할 수도 있다.

---

## 2. Build Phase

Build phase는 build 측 테이블의 모든 row를 hash table에 삽입한다.

### 2.1 Hash Join Build (`build_hash_join`)

**함수**: `cudf::detail::build_hash_join()` (`cpp/src/join/hash_join.cu:136-176`)

1. Row hasher 생성: primitive type이면 `row::primitive::row_hasher`, 아니면 `row::hash::row_hasher` 사용
2. 각 row에 대해 `pair_fn{d_hasher}` functor로 `(hash_value, row_index)` pair 생성 (`cpp/src/join/join_common_utils.cuh:23-33`)
3. `hash_table.insert()` 또는 `hash_table.insert_if()` 호출

```cpp
// cpp/src/join/hash_join.cu:149-161
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

- **Null 처리**: `null_equality::UNEQUAL`이고 nullable column이 있으면, `row_is_valid` predicate로 유효한 row만 삽입 (`insert_if`)
- **Bitmask**: `bitmask_and()`로 모든 key column의 null mask를 AND 연산하여 row 단위 validity mask 생성

### 2.2 Hash 함수

- **Default hash**: `cudf::hashing::detail::default_hash` (MurmurHash3 기반)
- Primitive type의 경우 `row::primitive::row_hasher` 사용으로 최적화
- 복합(nested/struct) type은 `row::hash::row_hasher`의 `device_hasher()`를 통해 row-level hashing 수행

### 2.3 Constructor에서의 Build

`hash_join` 객체 생성 시 constructor에서 hash table build가 완료된다 (`cpp/src/join/hash_join.cu:526-564`). 이는 한 번 build한 hash table을 여러 probe에 재사용할 수 있게 한다.

```cpp
// cpp/src/join/hash_join.cu:534-543
_hash_table{
    cuco::extent{static_cast<size_t>(build.num_rows())},
    load_factor,
    cuco::empty_key{cuco::pair{std::numeric_limits<hash_value_type>::max(), cudf::JoinNoMatch}},
    {}, {}, {}, {},
    rmm::mr::polymorphic_allocator<char>{},
    stream.value()},
```

---

## 3. Probe Phase

### 3.1 Two-pass Approach: Size Estimation + Retrieval

cuDF의 hash join probe는 **2-pass** 방식이다:

**Pass 1 — Size Estimation** (`compute_join_output_size`, `cpp/src/join/hash_join.cu:199-265`):
- `hash_table.count()` (inner join) 또는 `hash_table.count_outer()` (left join)로 결과 크기 계산
- Output buffer를 정확한 크기로 한 번에 할당

**Pass 2 — Result Retrieval** (`probe_join_hash_table`, `cpp/src/join/hash_join.cu:288-390`):
- `hash_table.retrieve()` (inner join) 또는 `hash_table.retrieve_outer()` (left/full join)로 실제 매칭 수행
- 결과를 `left_indices`, `right_indices` device vector에 저장

```cpp
// cpp/src/join/hash_join.cu:335-361
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

### 3.2 Equality Comparison

Probe 시 hash 충돌 해결을 위해 `pair_equal` comparator를 사용한다 (`cpp/src/join/hash_join.cu:77-95`):

1. Hash value 비교 (`lhs.first == rhs.first`)
2. Hash가 같으면 실제 row content equality check 수행 (`_check_row_equality`)

```cpp
__device__ __forceinline__ bool operator()(
    cuco::pair<hash_value_type, size_type> const& lhs,
    cuco::pair<hash_value_type, size_type> const& rhs) const noexcept
{
    return lhs.first == rhs.first and
           _check_row_equality(lhs_index_type{lhs.second}, rhs_index_type{rhs.second});
}
```

### 3.3 Output Size 사전 제공

사용자가 `output_size`를 optional로 전달하면 size estimation pass를 건너뛸 수 있다. 이를 통해 다중 probe 시 첫 probe에서 계산한 크기를 재사용할 수 있다.

---

## 4. Partitioning 전략

cuDF의 hash join은 **명시적인 radix partitioning이나 Grace Hash Join을 사용하지 않는다**. 대신:

- GPU의 대규모 병렬성에 의존: 수천 개의 thread가 동시에 hash table을 probe
- Open addressing 기반의 lock-free hash table이므로 partitioning 없이도 효율적
- GPU의 높은 memory bandwidth를 활용하여 random access 패턴의 비용을 상쇄

이는 CPU hash join (DuckDB의 radix partitioning 등)과 근본적으로 다른 접근법이다. CPU에서는 cache locality를 위해 partitioning이 필수적이지만, GPU에서는 수천 개의 concurrent thread가 memory latency를 hide하므로 partitioning의 이점이 상대적으로 작다.

**Inner join 최적화**: 작은 테이블을 build side로 자동 선택한다 (`cpp/src/join/join.cu:52-59`):

```cpp
if (right.num_rows() > left.num_rows()) {
    cudf::hash_join hj_obj(left, has_nulls, compare_nulls, CUCO_DESIRED_LOAD_FACTOR, stream);
    auto [right_result, left_result] = hj_obj.inner_join(right, std::nullopt, stream, mr);
    return std::pair(std::move(left_result), std::move(right_result));
}
```

---

## 5. Parallelism (GPU 병렬 처리)

### 5.1 Hash Join의 Thread-Level Parallelism

#### Build Phase
- cuco의 `insert()` / `insert_if()`는 내부적으로 CUDA kernel을 launch
- 각 GPU thread가 하나의 build row를 담당하여 hash table에 삽입
- Atomic operation 기반의 lock-free insert: open addressing에서 CAS(Compare-And-Swap)로 slot을 점유

#### Probe Phase
- cuco의 `count()`, `retrieve()`, `count_outer()`, `retrieve_outer()` 등이 각각 CUDA kernel
- 각 GPU thread가 하나의 probe row를 담당

### 5.2 Cooperative Groups (CG)

**Hash Join** (`DEFAULT_JOIN_CG_SIZE = 2`, `cpp/include/cudf/detail/join/join.hpp:12`):
- 2개의 thread가 하나의 cooperative group을 형성
- Probing 시 2개 thread가 동시에 2-slot bucket의 각 slot을 검사
- Double hashing + CG=2 + bucket_size=2 조합: 한 번의 memory access로 2개 slot을 병렬 검사

**Distinct Hash Join** (CG size = 1):
- 단일 thread가 probing 수행 (linear probing, bucket_size=1)
- 키가 unique하므로 match가 최대 1개 → CG 오버헤드 불필요

### 5.3 Conditional Join의 Warp-Level Parallelism

Conditional join은 cuco를 사용하지 않고 직접 CUDA kernel을 작성한다. Block size = 128 (`DEFAULT_JOIN_BLOCK_SIZE`, `cpp/src/join/join_common_utils.hpp:20`)이며, warp 단위로 협업한다.

```cpp
// cpp/src/join/conditional_join_kernels.cuh:246-249
constexpr int num_warps = block_size / detail::warp_size;
__shared__ std::size_t current_idx_shared[num_warps];
__shared__ cudf::size_type join_shared_l[num_warps][output_cache_size];
__shared__ cudf::size_type join_shared_r[num_warps][output_cache_size];
```

- **Grid 구성**: `grid_1d config(outer_num_rows, DEFAULT_JOIN_BLOCK_SIZE)` — outer table row 수를 기준으로 1D grid
- **각 thread**: 하나의 outer row를 담당하고, 모든 inner row와 nested loop으로 비교
- **Warp 단위 shared memory cache**: 각 warp가 독립적인 output cache를 유지
  - `add_pair_to_cache()` (`cpp/src/join/conditional_join_kernels.cuh:34-46`): warp 내 atomic으로 shared memory에 결과 추가
  - `flush_output_cache()` (`cpp/src/join/conditional_join_kernels.cuh:58-95`): cache가 가득 차면 global memory로 flush
  - Flush 시 lane 0이 global atomic으로 output offset 확보 후 `ShuffleIndex`로 warp 내 broadcast
- **__ballot_sync / __syncwarp**: warp 내 동기화 사용

### 5.4 Mixed Join의 2-Phase Precomputation

Mixed join은 register spilling 문제를 회피하기 위해 2-phase 접근법을 사용한다 (`cpp/src/join/mixed_join.cu:90-162`):

1. **Precompute phase** (`precompute_mixed_join_data`): 각 probe row의 hash value와 double hashing indices를 미리 계산
2. **Probe/retrieve phase**: precomputed data를 사용하여 직접 구현한 probing logic으로 매칭

이 방식은 cuco issue #761의 register spilling 문제를 우회하면서 legacy multimap 대비 약 **20% 성능 향상**을 달성한다.

### 5.5 Thread-Block 구성

| Join 유형 | Block Size | Grid Size | CG Size |
|-----------|-----------|-----------|---------|
| Hash Join (cuco) | cuco 내부 결정 | cuco 내부 결정 | 2 |
| Distinct Hash Join (cuco) | cuco 내부 결정 | cuco 내부 결정 | 1 |
| Conditional Join | 128 | `ceil(outer_rows / 128)` | N/A (warp 단위) |
| Mixed Join | 128 | `ceil(outer_rows / 128)` | N/A |

---

## 6. Memory Management

### 6.1 RMM (RAPIDS Memory Manager)

cuDF의 모든 GPU memory 할당은 **RMM**을 통해 이루어진다:

- **`rmm::device_uvector<T>`**: typed device memory 할당 (`cpp/src/join/hash_join.cu:323-324`)
- **`rmm::device_buffer`**: untyped device memory (bitmask 등)
- **`rmm::mr::polymorphic_allocator<char>`**: hash table 내부 할당에 사용 (`cpp/include/cudf/detail/join/hash_join.cuh:86`)
- **`rmm::device_async_resource_ref`**: 비동기 memory resource 참조 — 함수 인자로 전달되어 memory pool 선택 가능

### 6.2 Memory 할당 패턴

1. **Hash table**: build 시 `cuco::extent{build.num_rows()}` + load_factor로 크기 결정
2. **Output indices**: 2-pass 방식으로 정확한 크기를 먼저 계산한 후 한 번에 할당 → 메모리 낭비 없음
3. **Temporary buffers**: row bitmask (`bitmask_and`), complement indices 등은 임시 할당 후 자동 해제
4. **Prefetch**: output indices에 대해 `cudf::prefetch::detail::prefetch()` 호출로 GPU memory prefetching (`cpp/src/join/hash_join.cu:325-326`)

### 6.3 Spill-to-Disk

cuDF는 **spill-to-disk 메커니즘을 제공하지 않는다**. GPU memory (VRAM)에 hash table과 모든 데이터가 적재되어야 한다. Out-of-memory 상황은 RMM의 pool allocator나 managed memory를 통해 부분적으로 완화할 수 있지만, 근본적으로 GPU memory 용량에 의해 처리 가능한 데이터 크기가 제한된다.

### 6.4 Shared Memory 사용

Conditional join kernel에서 shared memory를 적극 활용한다:

- **Expression 중간 결과** 저장: `extern __shared__ char raw_intermediate_storage[]` — 각 thread의 AST expression evaluation 중간값
- **Output cache**: `join_shared_l[num_warps][output_cache_size]`, `join_shared_r[num_warps][output_cache_size]` — warp별 출력 버퍼
- **Cache size**: `DEFAULT_CACHE_SIZE = 128` (`cpp/src/join/conditional_join.cu:29`)
- Shared memory 크기: `parser.shmem_per_thread * config.num_threads_per_block` 로 동적 할당

---

## 7. Join Types 지원

### 7.1 Hash Join (`hash_join` 클래스)

`join_kind` enum으로 구분 (`cpp/src/join/hash_join.cu:569-600`):

| Join Type | 구현 방법 |
|-----------|----------|
| **INNER_JOIN** | `hash_table.retrieve()` — 매칭된 pair만 반환 |
| **LEFT_JOIN** | `hash_table.retrieve_outer()` — 매칭 없는 probe row는 `JoinNoMatch`로 |
| **FULL_JOIN** | LEFT_JOIN + complement indices 연결 (`get_left_join_indices_complement`, `cpp/src/join/join_utils.cu:70-136`) |

Full join은 LEFT_JOIN 결과에서 build side에서 매칭되지 않은 row를 찾아 concatenate한다:
```cpp
// cpp/src/join/hash_join.cu:824-828
if (join == join_kind::FULL_JOIN) {
    auto complement_indices = detail::get_left_join_indices_complement(
        join_indices.second, probe_table.num_rows(), _build.num_rows(), stream, mr);
    join_indices = detail::concatenate_vector_pairs(join_indices, complement_indices, stream);
}
```

### 7.2 Distinct Hash Join

- **INNER_JOIN**: `find_async()` 후 `JoinNoMatch`가 아닌 결과만 `copy_if`로 필터링 (`cpp/src/join/distinct_hash_join.cu:224-320`)
- **LEFT_JOIN**: `find_async()`/`find_if_async()` 결과를 그대로 반환 (no-match는 `JoinNoMatch`) (`cpp/src/join/distinct_hash_join.cu:322-402`)

### 7.3 Conditional Join

모든 join type 지원 (`cpp/src/join/conditional_join.cu:368-477`):
- `conditional_inner_join`, `conditional_left_join`, `conditional_full_join`
- `conditional_left_semi_join`, `conditional_left_anti_join`

Nested loop 기반 (hash table 없음)으로 AST expression을 매 pair에 대해 evaluate.

### 7.4 Mixed Join

Equality + expression 조건 결합 (`cpp/src/join/mixed_join.cu`):
- Equality 조건으로 hash table build/probe 후, expression 조건으로 추가 필터링
- Inner, left, full join 지원

### 7.5 Filtered Join (Semi/Anti)

`filtered_join` 클래스 (`cpp/src/join/filtered_join.cu`):
- `cuco::static_set` 기반으로 `contains` 연산 사용
- Semi join: build에 존재하는 probe row 반환
- Anti join: build에 존재하지 않는 probe row 반환

---

## 8. GPU 특화 분석

### 8.1 GPU Thread/Block/Warp와 Hash Join 알고리즘의 매핑

**Build Phase 매핑:**
- 1 GPU thread ↔ 1 build row insertion
- Hash table slot의 atomic CAS로 concurrent insert 보장
- `insert_if()`의 경우 stencil predicate로 conditional insert 수행 — branch divergence 최소화를 위해 predicate 기반

**Probe Phase 매핑 (Hash Join):**
- 1 Cooperative Group (2 threads) ↔ 1 probe row
- CG 내의 2 threads가 동시에 bucket의 2 slots를 검사 → memory access 횟수 절반
- 이는 GPU의 warp execution model과 잘 맞음: 32-thread warp에서 16개의 CG가 동시에 16개의 probe row를 처리

**Probe Phase 매핑 (Conditional Join):**
- 1 thread ↔ 1 outer row × 모든 inner rows (nested loop)
- Warp (32 threads) 내의 thread들은 서로 다른 outer row를 처리하되, output을 공유 shared memory cache에 모음
- `__ballot_sync`로 warp 내 동기화: cache flush 타이밍 조율

### 8.2 Shared Memory / Global Memory 활용 전략

**Global Memory:**
- Hash table 자체는 global memory에 위치 (device memory)
- Output index arrays (`left_indices`, `right_indices`)도 global memory
- cuco 기반 join에서는 shared memory를 직접 사용하지 않음 — cuco 내부 구현에 위임

**Shared Memory:**
- **Conditional join kernel**: output cache를 shared memory에 유지하여 global memory write 횟수 감소
  - 각 warp가 `output_cache_size=128`개 slot의 독립 cache 보유
  - Cache가 가득 차면 한 번에 global memory로 flush → coalesced write
- **Expression evaluation**: AST 중간값을 shared memory에 저장하여 register pressure 경감
- Shared memory 크기는 kernel launch 시 동적으로 결정: `shmem_size_per_block = parser.shmem_per_thread * config.num_threads_per_block`

### 8.3 CPU Hash Join과의 구조적 차이점

| 관점 | CPU (DuckDB 등) | GPU (cuDF) |
|------|-----------------|------------|
| **Hash Table** | Custom chaining 또는 open addressing, per-thread 또는 partitioned | cuco의 lock-free open addressing, global shared |
| **Partitioning** | Radix partitioning으로 cache-friendly 접근 | 없음 — GPU의 massive parallelism이 memory latency를 hide |
| **Build 병렬성** | 파티션별 독립 build (lock-free) | Atomic CAS 기반 concurrent insert into single hash table |
| **Probe 병렬성** | 파티션별 독립 probe | 수천 thread가 동시에 같은 hash table probe |
| **Memory 계층** | L1/L2/L3 cache 활용이 핵심 | GPU global memory bandwidth + shared memory cache |
| **Concurrency Model** | 수~수십 thread | 수만~수십만 thread |
| **출력 크기 결정** | Adaptive/dynamic growth (vector append) | 2-pass: 먼저 size 계산, 그 다음 정확한 크기로 할당 |
| **Spill-to-Disk** | Grace Hash Join 등 지원 | 미지원 — GPU memory 내에서만 동작 |
| **Hash 충돌 해결** | Linear probing / chaining / Robin Hood | Double hashing + cooperative groups |
| **Null 처리** | 별도 partition 또는 flag | Bitmask AND + predicate-based conditional insert/find |

**2-pass 접근의 근거:** CPU에서는 동적으로 output buffer를 grow할 수 있지만 (realloc), GPU에서는 kernel 실행 중 memory allocation이 비효율적이므로 size estimation pass를 먼저 수행한다. 이는 atomic counter 기반 output write의 부담도 줄여준다.

**Partitioning 불필요의 근거:** CPU hash join에서 radix partitioning의 핵심 목적은 cache miss 감소이다. GPU에서는 (1) 수천 개의 active thread가 memory latency를 hide하고, (2) GPU의 global memory bandwidth가 매우 높으며 (수백 GB/s), (3) warp 내 thread들의 divergent access도 hardware가 효율적으로 처리하므로, partitioning 없이도 높은 throughput을 달성한다.

### 8.4 cuCollections (cuco) 라이브러리 아키텍처

cuco는 NVIDIA에서 개발한 GPU-optimized concurrent data structures 라이브러리이다.

**핵심 특성:**
- **Lock-free**: 모든 연산이 atomic operation 기반으로 lock 없이 동작
- **Cooperative Groups 지원**: 복수 thread가 하나의 논리적 operation을 수행
- **Open addressing**: GPU에서 chaining보다 cache-friendly한 open addressing 채택
- **Probing schemes**: linear probing, double hashing 등 선택 가능
- **Bucket storage**: `cuco::storage<N>`으로 bucket당 N개의 slot — memory access granularity 조절

**cuDF에서의 사용:**
- `cuco::static_multiset`: hash join (duplicate keys 허용)
- `cuco::static_set`: distinct hash join, filtered join (unique keys)
- `insert()`, `insert_if()`, `insert_async()`, `insert_if_async()`: build phase
- `count()`, `count_outer()`, `count_each()`: size estimation
- `retrieve()`, `retrieve_outer()`: result materialization
- `find_async()`, `find_if_async()`: distinct join probe
- `contains_if_n()`: filtered (semi/anti) join

cuDF는 cuco의 public API와 일부 internal kernel (`cuco::detail::open_addressing_ns`) 모두를 사용하며, mixed join에서는 register spilling 문제로 인해 cuco의 probing logic을 직접 재구현하기도 한다 (`cpp/src/join/mixed_join_common_utils.cuh:155-249`).

---

## 9. Key References

### Source Code (RAPIDS cuDF, commit 기준 2025-2026)

| 파일 | 주요 함수/클래스 | 역할 |
|------|----------------|------|
| `cpp/src/join/hash_join.cu` | `build_hash_join()`, `compute_join_output_size()`, `probe_join_hash_table()`, `hash_join::compute_hash_join()` | Hash join core: build, size estimation, probe |
| `cpp/include/cudf/detail/join/hash_join.cuh` | `hash_join<Hasher>`, `hash_table_t` type alias | Hash join 클래스 정의, cuco multiset type 선언 |
| `cpp/src/join/join.cu` | `detail::inner_join()`, `detail::left_join()`, `detail::full_join()` | Join entry points, 작은 테이블을 build side로 선택 |
| `cpp/src/join/distinct_hash_join.cu` | `distinct_hash_join::inner_join()`, `distinct_hash_join::left_join()`, `find_matches_in_hash_table()` | Distinct hash join: cuco::static_set 기반 |
| `cpp/include/cudf/detail/join/distinct_hash_join.cuh` | `distinct_hash_join`, `hash_table_type`, `comparator_adapter` | Distinct hash join 클래스 정의 |
| `cpp/src/join/conditional_join.cu` | `conditional_join()`, `conditional_join_anti_semi()`, `compute_conditional_join_output_size()` | Conditional (non-equi) join |
| `cpp/src/join/conditional_join_kernels.cuh` | `conditional_join<>` kernel, `add_pair_to_cache()`, `flush_output_cache()` | GPU kernel: warp-level output caching |
| `cpp/src/join/mixed_join.cu` | `setup_mixed_join_common()`, `precompute_mixed_join_data()` | Mixed join: equality + expression |
| `cpp/src/join/mixed_join_kernel.cuh` | `mixed_join<>` kernel, `retrieve_matches()` | Mixed join GPU kernel |
| `cpp/src/join/mixed_join_common_utils.cuh` | `mixed_multiset_type`, `pair_expression_equality`, `hash_table_prober` | Mixed join 유틸: hash table type, probe logic |
| `cpp/src/join/join_common_utils.cuh` | `pair_fn`, `row_is_valid`, `valid_range` | 공통 유틸: hash pair 생성, null validity check |
| `cpp/src/join/join_common_utils.hpp` | `DEFAULT_JOIN_BLOCK_SIZE = 128` | Block size 상수 |
| `cpp/include/cudf/detail/join/join.hpp` | `DEFAULT_JOIN_CG_SIZE = 2` | Cooperative group size 상수 |
| `cpp/include/cudf/detail/cuco_helpers.hpp` | `CUCO_DESIRED_LOAD_FACTOR = 0.5` | Hash table load factor |
| `cpp/src/join/join_utils.cu` | `get_trivial_left_join_indices()`, `get_left_join_indices_complement()`, `concatenate_vector_pairs()` | Full join complement, trivial join handling |
| `cpp/src/join/filtered_join.cu` | `filtered_join`, `distinct_filtered_join::semi_anti_join()` | Semi/anti join: cuco::static_set 기반 |

### 논문 및 외부 참고 자료

- **"Triton Join: Efficiently Scaling to a Large Join State on GPUs with Fast Interconnects"** (Lutz et al., SIGMOD 2022) — GPU hash join의 large-state 처리 관련 연구. cuDF의 접근법(single hash table, no partitioning)과 대비되는 partitioned GPU join 전략 제시.
- **cuCollections (cuco)**: https://github.com/NVIDIA/cuCollections — cuDF가 의존하는 GPU concurrent hash table 라이브러리. Static multiset, static set 등의 GPU-optimized open addressing 구현 제공.
- **RMM (RAPIDS Memory Manager)**: https://github.com/rapidsai/rmm — cuDF의 GPU memory 관리 라이브러리. Pool allocator, managed memory 등 다양한 memory resource 지원.
