# Polars Hash Join Partitioning 전략 심층 분석

## 요약

Polars의 hash join partitioning은 **병렬 hash table 구축 및 probe를 위한 데이터 분배 메커니즘**이다. DuckDB의 radix partitioning이 메모리 관리(grace hash join)를 위한 것인 반면, Polars의 partitioning은 순수하게 **thread-level parallelism**을 목적으로 한다.

핵심 특성:
- **파티션 수 = thread 수**: `POOL.current_num_threads()`로 파티션 수가 결정되며, 데이터 크기와 무관하다.
- **두 가지 파티셔닝 방식**: inner/left join의 `build_tables`는 scatter 기반 3단계 파티셔닝을 사용하고, outer/semi/anti join은 filter 기반 파티셔닝을 사용한다.
- **Spill-to-disk 없음**: In-memory 전용 설계로, 메모리 초과 시 OOM이 발생한다.
- **DirtyHash 기반 파티션 매핑**: `hash_to_partition()`이 hash 상위 비트를 활용한 곱셈 기반 매핑으로 파티션 인덱스를 결정한다.

---

## Partitioning 개요

### 파티션 수 결정

Polars에서 파티션 수는 join type에 따라 두 가지 방식으로 결정된다:

#### (1) Inner/Left Join: `build_tables`의 입력 기반

`build_tables` 함수는 `keys: Vec<I>` 파라미터를 받으며, 이 vector의 길이가 곧 파티션 수이다 (`single_keys.rs:27-28`):

```rust
let n_partitions = keys.len();
let n_threads = n_partitions;
```

이 `keys` vector는 호출 측(`single_keys_dispatch.rs`)에서 `split(array, n_threads)`로 생성된다. `split` 함수는 ChunkedArray를 `n_threads` 개의 sub-array로 분할하며, `n_threads`는 `POOL.current_num_threads()`이다 (`single_keys_dispatch.rs:478-481`):

```rust
let n_threads = POOL.current_num_threads();
let (a, b, swapped) = det_hash_prone_order!(left, right);
let splitted_a = split(a, n_threads);
let splitted_b = split(b, n_threads);
```

따라서 **파티션 수 = Rayon thread pool의 thread 수**이다.

#### (2) Outer/Semi/Anti Join: `_set_partition_size()` 사용

Outer join의 `prepare_hashed_relation_threaded`와 semi/anti join의 `build_table_semi_anti`는 `_set_partition_size()`를 호출한다 (`single_keys_outer.rs:47`, `single_keys_semi_anti.rs:17`):

```rust
let n_partitions = _set_partition_size();
```

`_set_partition_size()`는 `polars-core/src/utils/mod.rs`에 정의되어 있으며, 역시 `POOL.current_num_threads()`를 반환한다:

```rust
pub fn _set_partition_size() -> usize {
    POOL.current_num_threads()
}
```

결론적으로 모든 join type에서 **파티션 수 = thread 수**이다. `POLARS_MAX_THREADS` 환경변수로 thread 수를 조절하면 파티션 수도 함께 변경된다.

### hash_to_partition: Hash 기반 파티션 분배

파티션 인덱스 결정은 `polars-utils/src/hashing.rs`의 `hash_to_partition` 함수가 담당한다:

```rust
// polars-utils/src/hashing.rs:66-72
pub fn hash_to_partition(h: u64, n_partitions: usize) -> usize {
    // Assuming h is a 64-bit random number, we note that
    // h / 2^64 is almost a uniform random number in [0, 1), and thus
    // floor(h * n_partitions / 2^64) is almost a uniform random integer in
    // [0, n_partitions). Despite being written with u128 multiplication this
    // compiles to a single mul / mulhi instruction on x86-x64/aarch64.
    ((h as u128 * n_partitions as u128) >> 64) as usize
}
```

이 함수는 hash 값의 **상위 비트**를 활용하여 파티션을 결정한다. `h * n_partitions`의 128-bit 곱셈 후 상위 64비트를 취하는 방식으로, `h % n_partitions`보다 균일한 분포를 보장하면서도 단일 `mul`/`mulhi` instruction으로 컴파일된다. 나머지(modulo) 연산이 아니므로 power-of-two가 아닌 파티션 수에서도 편향이 적다.

### DirtyHash: 파티셔닝 전용 경량 해시

Inner/left join의 `build_tables`와 probe에서는 full hash 대신 `DirtyHash` trait을 사용한다. 이는 파티셔닝 목적으로만 사용되는 경량 해시이다:

```rust
// polars-utils/src/hashing.rs:124-128
pub trait DirtyHash {
    // A quick and dirty hash. Only the top bits of the hash are decent, such as
    // used in hash_to_partition.
    fn dirty_hash(&self) -> u64;
}

// 정수형 구현: 단순 곱셈
const RANDOM_ODD: u64 = 0x55fbfd6bfc5458e9;
impl DirtyHash for u64 {
    fn dirty_hash(&self) -> u64 {
        (*self as u64).wrapping_mul(RANDOM_ODD)
    }
}
```

상위 비트만 의미 있는 "dirty" hash이지만, `hash_to_partition()`이 정확히 상위 비트를 사용하므로 파티셔닝에는 충분하다. Full hash (ahash/xxh3)는 hash table 내부의 slot 결정에만 사용된다. 이 분리를 통해 파티셔닝 비용을 최소화한다.

---

## Build-Side Partitioning

### 방식 1: Scatter 기반 3단계 파티셔닝 (Inner/Left Join)

`build_tables` 함수 (`single_keys.rs:16-167`)는 Polars hash join의 핵심 build 로직이다. 3단계 scatter 기반 파티셔닝을 수행한다:

#### Stage 1: Partition Size Counting (병렬)

각 thread가 자신의 key portion을 순회하며 각 파티션에 속하는 key 수를 센다:

```rust
// single_keys.rs:52-66
let per_thread_partition_sizes: Vec<Vec<usize>> = keys
    .par_iter()
    .with_max_len(1)
    .map(|key_portion| {
        let mut partition_sizes = vec![0; n_partitions];
        for key in key_portion.clone() {
            let key = key.to_total_ord();
            let p = hash_to_partition(key.dirty_hash(), n_partitions);
            *partition_sizes.get_unchecked_mut(p) += 1;
        }
        partition_sizes
    })
    .collect();
```

결과는 `per_thread_partition_sizes[thread][partition]` 형태의 2D 행렬이다.

#### Stage 2: Offset 계산 + Scatter (병렬)

Prefix sum으로 각 `(thread, partition)` 조합의 global offset을 계산한 뒤, 각 thread가 자신의 key를 해당 위치에 직접 scatter한다:

```rust
// single_keys.rs:68-81 — offset 계산
let mut per_thread_partition_offsets = vec![0; n_partitions * n_threads + 1];
let mut partition_offsets = vec![0; n_partitions + 1];
let mut cum_offset = 0;
for p in 0..n_partitions {
    partition_offsets[p] = cum_offset;
    for t in 0..n_threads {
        per_thread_partition_offsets[t * n_partitions + p] = cum_offset;
        cum_offset += per_thread_partition_sizes[t][p];
    }
}

// single_keys.rs:96-121 — scatter
let mut scatter_keys: Vec<T::TotalOrdItem> = Vec::with_capacity(num_keys);
let mut scatter_idxs: Vec<IdxSize> = Vec::with_capacity(num_keys);
let scatter_keys_ptr = unsafe { SyncPtr::new(scatter_keys.as_mut_ptr()) };
let scatter_idxs_ptr = unsafe { SyncPtr::new(scatter_idxs.as_mut_ptr()) };
keys.into_par_iter().with_max_len(1).enumerate().for_each(|(t, key_portion)| {
    let mut partition_offsets = per_thread_partition_offsets[t * n_partitions..(t+1) * n_partitions].to_vec();
    for (i, key) in key_portion.into_iter().enumerate() {
        let key = key.to_total_ord();
        let p = hash_to_partition(key.dirty_hash(), n_partitions);
        let off = partition_offsets.get_unchecked_mut(p);
        *scatter_keys_ptr.get().add(*off) = key;
        *scatter_idxs_ptr.get().add(*off) = (per_thread_input_offsets[t] + i) as IdxSize;
        *off += 1;
    }
});
```

`SyncPtr`을 사용하여 각 thread가 서로 다른 메모리 영역에 lock-free로 동시에 쓴다. 이 scatter 방식의 핵심 이점은:
- 각 thread가 자신의 key portion만 한 번 순회하므로 input은 sequential access
- Output은 partition별로 연속된 메모리에 배치되므로 다음 stage에서 cache-friendly

#### Stage 3: Hash Map Build (병렬)

각 파티션의 연속 메모리 영역에서 독립적인 `PlHashMap`을 구축한다:

```rust
// single_keys.rs:124-165
(0..n_partitions).into_par_iter().with_max_len(1).map(|p| {
    let partition_range = partition_offsets[p]..partition_offsets[p + 1];
    let full_size = partition_range.len();
    let mut conservative_size = _HASHMAP_INIT_SIZE.max(full_size / 64);
    let mut hm: PlHashMap<T::TotalOrdItem, IdxVec> =
        PlHashMap::with_capacity(conservative_size);

    for i in partition_range {
        if hm.len() == conservative_size {
            hm.reserve(full_size - conservative_size);
            conservative_size = 0;
        }
        let key = *scatter_keys.get_unchecked(i);
        if !key.is_null() || nulls_equal {
            let idx = *scatter_idxs.get_unchecked(i);
            match hm.entry(key) {
                Entry::Occupied(mut o) => o.get_mut().push(idx as IdxSize),
                Entry::Vacant(v) => { v.insert(unitvec![idx as IdxSize]); },
            };
        }
    }
    hm
}).collect()
```

각 파티션의 hash table은 완전히 독립적이므로 lock이 필요 없다. Hybrid sizing 전략 (초기 `max(512, full_size/64)` -> 필요시 full reserve)으로 skewed distribution에도 효율적으로 대응한다.

#### 소량 데이터 최적화

전체 key 수가 `2 * MIN_ELEMS_PER_THREAD` (release: 256, debug: 2) 미만이면 파티셔닝을 건너뛰고 단일 thread에서 하나의 hash map을 직접 생성한다 (`single_keys.rs:35-48`):

```rust
if num_keys_est < 2 * MIN_ELEMS_PER_THREAD {
    let mut hm: PlHashMap<T::TotalOrdItem, IdxVec> = PlHashMap::new();
    // ... 단일 thread로 직접 build
    return vec![hm];
}
```

### 방식 2: Filter 기반 파티셔닝 (Outer/Semi/Anti Join)

Outer join의 `prepare_hashed_relation_threaded` (`single_keys_outer.rs:39-97`)와 semi/anti join의 `build_table_semi_anti` (`single_keys_semi_anti.rs:8-37`)는 scatter가 아닌 **filter 기반** 파티셔닝을 사용한다.

#### Outer Join Build

```rust
// single_keys_outer.rs:47-96
let n_partitions = _set_partition_size();
let (hashes_and_keys, build_hasher) = create_hash_and_keys_threaded_vectorized(iters, None);

POOL.install(|| {
    (0..n_partitions).into_par_iter().map(|partition_no| {
        let mut hash_tbl: PlHashMap<T::TotalOrdItem, (bool, IdxVec)> =
            PlHashMap::with_hasher(build_hasher.clone());
        let mut offset = 0;
        for hashes_and_keys in hashes_and_keys {
            hashes_and_keys.iter().enumerate().for_each(|(idx, (h, k))| {
                // 이 파티션에 해당하는 key만 처리
                if partition_no == hash_to_partition(*h, n_partitions) {
                    // hash table에 삽입
                    let entry = hash_tbl.raw_entry_mut()
                        .from_key_hashed_nocheck(*h, &k);
                    // ...
                }
            });
            offset += len as IdxSize;
        }
        hash_tbl
    }).collect()
})
```

이 방식의 특징:
- **각 thread가 전체 데이터를 순회**하며 자신의 파티션에 해당하는 key만 처리한다.
- Scatter 방식보다 효율이 낮다 (각 thread가 `n_partitions - 1` 만큼의 key를 skip).
- Hash 값을 `(u64, T)` 쌍으로 사전 계산하여 hash table 삽입 시 `from_key_hashed_nocheck`로 재해싱을 회피한다.
- Value가 `(bool, IdxVec)` 형태로, `bool` tracker는 probe 시 매칭 여부를 추적한다.

주석에서도 이 방식을 인정하고 있다:
> `"We will create a hashtable in every thread. We use the hash to partition the keys to the matching hashtable. Every thread traverses all keys/hashes and ignores the ones that doesn't fall in that partition."` (`single_keys_outer.rs:50-52`)

#### Semi/Anti Join Build

```rust
// single_keys_semi_anti.rs:17-36
let n_partitions = _set_partition_size();
let par_iter = (0..n_partitions).into_par_iter().map(|partition_no| {
    let mut hash_tbl: PlHashSet<T::TotalOrdItem> = PlHashSet::with_capacity(_HASHMAP_INIT_SIZE);
    for keys in &keys {
        keys.into_iter().for_each(|k| {
            let k = k.to_total_ord();
            if partition_no == hash_to_partition(k.dirty_hash(), n_partitions)
                && (!k.is_null() || nulls_equal)
            {
                hash_tbl.insert(k);
            }
        });
    }
    hash_tbl
});
POOL.install(|| par_iter.collect())
```

`PlHashSet`만 사용하므로 인덱스 저장이 불필요하다. 마찬가지로 filter 기반으로 각 thread가 전체 데이터를 순회한다.

### 두 방식의 비교

| 속성 | Scatter 기반 (`build_tables`) | Filter 기반 (`prepare_hashed_relation_threaded` 등) |
|------|-----|-----|
| **사용 join type** | Inner, Left | Outer, Semi, Anti |
| **전체 데이터 순회** | 각 thread는 자기 portion만 | 각 thread가 전체 데이터를 순회 |
| **메모리 overhead** | `scatter_keys` + `scatter_idxs` 임시 버퍼 | Hash + key 쌍 사전 계산 |
| **구현 복잡도** | 높음 (3단계, prefix sum, SyncPtr) | 낮음 (단순 filter) |
| **Hash 사용** | DirtyHash (파티셔닝), full hash (hash table) | Full hash (파티셔닝 + hash table 동시) |

`build_tables`의 scatter 방식이 더 효율적이며, 코드 내 TODO 주석 (`single_keys.rs:10-12`)은 향후 모든 join type에서 thread 수와 별도로 최적 파티션 수를 계산하는 것을 고려하고 있다:
```rust
// TODO: we should compute the number of threads / partition size we'll use.
// let avail_threads = POOL.current_num_threads();
// let n_threads = (num_keys / MIN_ELEMS_PER_THREAD).clamp(1, avail_threads);
```

---

## Probe-Side Partitioning

### Probe 측 "파티셔닝"

Probe 측은 별도의 파티셔닝 단계가 **없다**. 대신 probe 데이터를 thread 수만큼 `split`으로 분할하고, 각 thread가 자신의 분할된 probe chunk를 독립적으로 처리한다.

Probe 시 build-side hash table은 immutable로 공유된다. 각 probe key에 대해 `hash_to_partition()`으로 해당 파티션의 hash table을 찾아서 조회한다:

```rust
// single_keys_inner.rs:24-31
probe.into_iter().enumerate_idx().for_each(|(idx_a, k)| {
    let k = k.to_total_ord();
    let idx_a = idx_a + local_offset;
    let current_probe_table =
        unsafe { hash_tbls.get_unchecked(hash_to_partition(k.dirty_hash(), n_tables)) };
    let value = current_probe_table.get(&k);
    // ...
});
```

핵심 구조: **probe 데이터 분할은 build-side partition과 독립적**이다. Probe chunk의 각 key가 build-side의 어느 파티션에 속하는지는 `hash_to_partition()`이 런타임에 결정한다. 따라서 하나의 probe chunk가 여러 build-side 파티션에 접근할 수 있다.

### Join Type별 Probe 구조

| Join Type | Probe 병렬화 | Build table 접근 방식 |
|-----------|-------------|---------------------|
| **Inner** | 병렬 (`par_iter`) | Immutable 공유, random access |
| **Left** | 병렬 (`par_iter`) | Immutable 공유, random access |
| **Outer** | **단일 thread** | Mutable (tracker bool 수정) |
| **Semi/Anti** | 병렬 (`par_iter`) | Immutable 공유 (PlHashSet) |

Outer join의 probe가 단일 thread인 이유는 build-side hash table의 `bool` tracker를 mutable하게 수정해야 하기 때문이다:

```rust
// single_keys_outer.rs:148-149
let (tracker, indexes_b) = occupied.get_mut();
*tracker = true;  // mutable 수정 → lock-free 병렬화 불가
```

소스 코드 주석에서도 이를 명시한다:
> `"during the probe phase values are removed from the tables, that's done single threaded to keep it lock free."` (`single_keys_outer.rs:203-204`)

### 결과 Materialization

Probe 결과의 병합도 파티셔닝 관점에서 중요하다:

- **Inner join**: 각 thread의 `Vec<(IdxSize, IdxSize)>` 결과를 `cap_and_offsets`로 총 크기 계산 후, `SyncPtr` 기반 lock-free 병렬 memcpy로 최종 left/right 인덱스 벡터를 구축한다 (`single_keys_inner.rs:114-146`).
- **Left join**: `flatten_left_join_ids`가 `flatten_par`를 사용하여 병렬로 결과를 병합한다 (`single_keys_left.rs:59-104`).
- **Semi/Anti join**: Rayon의 `flat_map` + `filter`로 streaming 방식 결과 수집 (`single_keys_semi_anti.rs:61-93`).

---

## 병렬 처리와 Partitioning

### 파티셔닝이 병렬성을 보장하는 방식

Polars의 partitioning이 병렬 처리를 가능하게 하는 핵심 원리:

1. **Build phase**: 같은 hash를 가진 key는 반드시 같은 파티션에 배치된다. 따라서 각 파티션의 hash table을 독립적으로 구축할 수 있다. Thread 간 동기화가 불필요하다.

2. **Probe phase**: Build-side hash table이 immutable이므로, 여러 thread가 동시에 읽을 수 있다. `hash_to_partition()`으로 올바른 hash table을 찾기만 하면 된다.

3. **Scatter 단계**: 각 thread의 output offset이 prefix sum으로 사전 결정되므로, thread들이 서로 다른 메모리 영역에 동시에 쓸 수 있다 (`SyncPtr` 기반 lock-free write).

### Rayon `with_max_len(1)` 설정

Build phase의 모든 `par_iter`에 `with_max_len(1)`이 설정되어 있다:

```rust
keys.par_iter().with_max_len(1).map(...)
```

이는 Rayon의 work-stealing scheduler가 각 iteration을 별도 task로 처리하도록 보장한다. 파티션 간 데이터 불균형이 있을 때 한 thread의 작업이 끝나면 다른 thread의 작업을 steal하여 load balancing이 이루어진다.

### 파티셔닝의 한계

- **파티션 수 = thread 수**로 고정되어 있어 cache 최적화 목적의 fine-grained partitioning은 수행하지 않는다.
- 데이터가 매우 skewed된 경우 (대부분의 key가 하나의 파티션에 집중), 해당 파티션의 hash table이 불균형하게 커질 수 있다. Rayon의 work-stealing이 task-level balancing은 해주지만, 메모리 불균형은 해결하지 못한다.
- 외부 저장소로의 spill-to-disk 메커니즘이 없으므로, 대규모 데이터에서 메모리 초과 시 OOM이 발생한다.

---

## DuckDB와의 비교

| 속성 | Polars | DuckDB |
|------|--------|--------|
| **파티셔닝 목적** | Thread-level 병렬 hash table 구축/probe | Grace hash join 메모리 관리 |
| **파티션 수 결정** | `POOL.current_num_threads()` (고정) | `INITIAL_RADIX_BITS=4` (16개) 시작, 동적 증가 |
| **파티셔닝 방식** | Hash 상위 비트 곱셈 (`h * n / 2^64`) | Hash 상위 비트 마스킹 (`(h & MASK) >> SHIFT`) |
| **Repartitioning** | 없음 | Radix bits 증가로 계층적 세분화 (hash 재계산 불필요) |
| **Spill-to-disk** | 없음 (OOM) | ProbeAndSpill: probe와 동시에 active/spill 분리 |
| **Build 파티셔닝** | 3단계 scatter (count → prefix sum → scatter) | Streaming append (histogram 없이 chunk 단위) |
| **Probe 파티셔닝** | 없음 (probe data는 단순 분할, hash table random access) | 없음 (ProbeAndSpill로 동시 수행) |
| **In-memory join** | 파티셔닝이 항상 사용됨 (병렬화 목적) | `Unpartition()`으로 16개를 하나로 합침 (파티셔닝 무시) |
| **Hash table 구조** | 파티션당 독립 PlHashMap (Swiss table) | 단일 hash table (chaining 기반) |

핵심 차이: DuckDB는 메모리보다 큰 데이터를 처리하기 위해 파티셔닝을 사용하고 in-memory에서는 파티셔닝을 무시하지만, Polars는 반대로 in-memory 병렬 처리를 위해 파티셔닝을 항상 활용하면서 out-of-core 처리는 지원하지 않는다.

---

## Key References

### 소스 코드 경로

| 파일 | 핵심 함수/상수 | 역할 |
|------|--------------|------|
| `crates/polars-ops/src/frame/join/hash_join/single_keys.rs` | `build_tables()` (L16-167), `MIN_ELEMS_PER_THREAD` (L14) | Scatter 기반 3단계 병렬 파티셔닝 + hash table build |
| `crates/polars-ops/src/frame/join/hash_join/single_keys.rs` | `probe_to_offsets()` (L170-183) | Probe 분할 offset 계산 |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_inner.rs` | `probe_inner()` (L11-38) | 파티션된 hash table에서 inner join probe |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_inner.rs` | `hash_join_tuples_inner()` (L40-149) | Inner join 전체 파이프라인 (build + probe + materialize) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_left.rs` | `hash_join_tuples_left()` (L106-195) | Left join 전체 파이프라인 |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_outer.rs` | `prepare_hashed_relation_threaded()` (L39-97) | Filter 기반 outer join build (tracker 포함) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_outer.rs` | `probe_outer()` (L101-178) | 단일 thread outer join probe |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_semi_anti.rs` | `build_table_semi_anti()` (L8-37) | Filter 기반 semi/anti join build (PlHashSet) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_semi_anti.rs` | `semi_anti_impl()` (L41-93) | Semi/anti join probe (ParallelIterator) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_dispatch.rs` | `group_join_inner()` (L464-541) | Inner join 진입점: split, build side 결정 |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_dispatch.rs` | `hash_join_outer()` (L641-682) | Outer join 진입점: `_set_partition_size()` 사용 |
| `crates/polars-ops/src/frame/join/hash_join/mod.rs` | `det_hash_prone_order!` (L40-49) | Build side 결정 매크로 |
| `crates/polars-core/src/utils/mod.rs` | `_set_partition_size()` | 파티션 수 = `POOL.current_num_threads()` |
| `crates/polars-core/src/utils/mod.rs` | `split()` (L238-256) | ChunkedArray를 n개로 분할 |
| `crates/polars-core/src/lib.rs` | `POOL`, `THREAD_POOL` (L50, L192) | Rayon thread pool 정의 |
| `crates/polars-utils/src/hashing.rs` | `hash_to_partition()` (L66-72) | Hash -> 파티션 인덱스 매핑 (곱셈 기반) |
| `crates/polars-utils/src/hashing.rs` | `DirtyHash` trait (L124-128) | 파티셔닝 전용 경량 해시 |
| `crates/polars-core/src/hashing/mod.rs` | `_HASHMAP_INIT_SIZE` (L11) | Hash map 초기 크기 = 512 |

### 분석 기준 소스 커밋

- Polars commit `6edb898` ("chore: Update docs (#26560)") 기준으로 분석.
