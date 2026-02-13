# Polars Hash Join 구현 분석

## 1. Hash Table 구조

### hashbrown 기반 Swiss Table

Polars는 Rust 표준 라이브러리의 `HashMap` 대신 **hashbrown** 라이브러리를 사용한다. `Cargo.toml`에서 `hashbrown = "0.16.0"` 버전을 사용하며, `rayon` feature를 활성화하여 병렬 처리를 지원한다.

- **`PlHashMap<K, V>`**: hashbrown의 `HashMap`을 기반으로 한 type alias로, Swiss Table 알고리즘을 사용한다.
  - Swiss Table은 SIMD 기반 parallel probing을 지원하는 open addressing hash table이다.
  - 128-bit control byte 그룹을 사용하여 한 번에 16개 슬롯을 병렬로 검사할 수 있다.
- **`PlHashSet<K>`**: hashbrown의 `HashSet` 기반으로, semi/anti join에서 membership 확인용으로 사용된다.
- **`PlRandomState`**: hash seed를 결정하는 random state로, join의 양쪽에 동일한 seed를 공유한다.

> 소스: `crates/polars-ops/src/frame/join/mod.rs:29` — `use hashbrown::hash_map::{Entry, RawEntryMut};`

### Hash 함수

- **정수형 타입**: `ahash`의 `hash_one` 메서드를 통해 해싱한다 (`vector_hasher.rs:94`).
- **Binary/String 타입**: `xxhash-rust`의 `xxh3_64_with_seed`를 사용한다 (`vector_hasher.rs:8`, `vector_hasher.rs:216`).
- **Hash combine**: 다중 키 해싱 시 `folded_multiply` 연산으로 기존 해시와 새 해시를 결합한다 (`vector_hasher.rs:121-127`). 단순 XOR이 아닌 folded multiplication을 사용하여 동일한 값을 가진 두 컬럼의 해시가 0이 되는 문제를 방지한다.
- **Null 처리**: null 값에 대해 별도의 고정 해시값(`get_null_hash_value`)을 계산하여, null 유무와 관계없이 일관된 해시 결과를 보장한다 (`vector_hasher.rs:37-42`).
- **초기 크기**: `_HASHMAP_INIT_SIZE = 512`로 설정하여 과도한 초기 할당을 방지한다 (`hashing/mod.rs:11`).

### Hybrid Sizing 전략

Build table 생성 시 **hybrid sizing 전략**을 적용한다. 초기에는 보수적으로 `max(512, full_size / 64)` 크기로 할당하여 skewed distribution에 효율적으로 대응한다. 이 초기 크기가 가득 차면 즉시 full cardinality 크기로 reserve한다 (`single_keys.rs:131-143`).

```rust
// single_keys.rs:135-143
let mut conservative_size = _HASHMAP_INIT_SIZE.max(full_size / 64);
let mut hm: PlHashMap<T::TotalOrdItem, IdxVec> =
    PlHashMap::with_capacity(conservative_size);
// ...
if hm.len() == conservative_size {
    hm.reserve(full_size - conservative_size);
    conservative_size = 0; // 다시 이 분기에 들어오지 않도록
}
```

## 2. Build Phase

### Build Side 결정

**Build side는 항상 짧은(shorter) relation을 선택한다.** `det_hash_prone_order!` 매크로가 이를 담당한다 (`hash_join/mod.rs:40-49`):

```rust
macro_rules! det_hash_prone_order {
    ($self:expr, $other:expr) => {{
        if $self.len() > $other.len() {
            ($self, $other, false)
        } else {
            ($other, $self, true)
        }
    }};
}
```

Inner join과 full outer join에서 `swapped` 플래그로 결과 인덱스의 좌우를 추적한다. Left join에서는 항상 right side를 build side로 사용한다.

### Partitioned Build (single_keys.rs::build_tables)

**`build_tables` 함수** (`single_keys.rs:16-167`)가 핵심 build 로직이다. 3단계로 진행된다:

1. **Partition size 계산 (1차 병렬)**: 각 thread가 자신의 key portion을 순회하며, `hash_to_partition(key.dirty_hash(), n_partitions)`으로 각 partition에 속하는 key 수를 센다.
2. **Scatter (2차 병렬)**: prefix sum으로 계산된 offset을 기반으로, 각 thread가 자신의 key를 해당 partition 위치에 scatter한다. `SyncPtr`을 사용하여 lock-free로 서로 다른 메모리 영역에 동시에 쓴다.
3. **Build hash maps (3차 병렬)**: 각 partition별로 독립적인 `PlHashMap`을 구축한다. key → `IdxVec` (인덱스 벡터) 매핑을 만든다.

소량 데이터의 경우 (`num_keys < 2 * MIN_ELEMS_PER_THREAD`), 직접 단일 thread로 `PlHashMap`을 생성하여 병렬화 overhead를 회피한다 (`single_keys.rs:35-48`).

### Outer Join용 Build (single_keys_outer.rs::prepare_hashed_relation_threaded)

Full outer join은 별도의 build 함수 `prepare_hashed_relation_threaded` (`single_keys_outer.rs:39-97`)를 사용한다. 이 함수는:
- 먼저 `create_hash_and_keys_threaded_vectorized`로 모든 key에 대해 `(hash, key)` 쌍을 병렬 생성한다.
- 각 thread가 `n_partitions`개의 파티션 중 자신의 파티션에 해당하는 key만 hash table에 삽입한다.
- **Tracker 포함**: value가 `(bool, IdxVec)` 형태로, `bool`은 probe 중 매칭 여부를 추적하여 unmatch된 build-side 행을 나중에 출력할 수 있다.

### Semi/Anti Join용 Build (single_keys_semi_anti.rs::build_table_semi_anti)

Semi/anti join은 인덱스 목록이 필요 없으므로 `PlHashSet`을 사용한다 (`single_keys_semi_anti.rs:8-37`). 마찬가지로 partition 기반으로 병렬 구축한다.

## 3. Probe Phase

### Inner Join Probe (single_keys_inner.rs::probe_inner)

`probe_inner` 함수 (`single_keys_inner.rs:11-38`)가 핵심 probe 로직이다:

1. 각 probe key에 대해 `hash_to_partition(k.dirty_hash(), n_tables)`로 해당 partition의 hash table을 찾는다.
2. hash table에서 `get(&k)`으로 매칭을 수행한다.
3. 매칭 발견 시 build-side의 `IdxVec`에 있는 모든 인덱스와 쌍을 만든다.
4. `swap_fn`을 통해 swapped 여부에 따라 (left_idx, right_idx) 순서를 조정한다.

Probe 결과는 **2단계 materialization**으로 처리된다 (`single_keys_inner.rs:114-146`):
- 각 thread의 결과 `Vec<(IdxSize, IdxSize)>`를 수집한 후
- `cap_and_offsets`로 총 크기와 오프셋을 계산하고
- `SyncPtr` 기반 lock-free 병렬 복사로 최종 left/right 인덱스 벡터를 구축한다.

### Left Join Probe (single_keys_left.rs::hash_join_tuples_left)

Left join probe (`single_keys_left.rs:106-195`)는 inner와 유사하나:
- 매칭이 없는 경우 `NullableIdxSize::null()`을 right 인덱스에 추가하여 null을 표현한다.
- `chunk_mapping`을 통해 multi-chunk된 ChunkedArray의 global index를 `ChunkId`로 변환할 수 있다.
- 결과는 `flatten_left_join_ids`로 병합된다 (`single_keys_left.rs:59-104`).

### Full Outer Join Probe (single_keys_outer.rs::probe_outer)

Outer join probe (`single_keys_outer.rs:101-178`)는 **단일 thread**에서 수행된다:
- Build 시 hash table의 value에 `bool` tracker를 둬서 매칭 여부를 기록한다.
- Probe 완료 후, tracker가 false인 build-side 행들을 right-only 결과로 추가한다.
- 이 probe phase는 hash table의 mutable state를 수정해야 하므로 lock-free 병렬화가 어렵다.

> 소스 코드 주석: `"during the probe phase values are removed from the tables, that's done single threaded to keep it lock free."` (`single_keys_outer.rs:203-204`)

### Semi/Anti Join Probe (single_keys_semi_anti.rs::semi_anti_impl)

Semi/anti join probe (`single_keys_semi_anti.rs:41-93`)는 `PlHashSet`의 membership만 확인한다:
- `(idx, bool)` 튜플을 생성하여 매칭 여부를 기록한다.
- Anti join: `filter(|t| !t.1)` — 매칭되지 않은 행만 수집
- Semi join: `filter(|t| t.1)` — 매칭된 행만 수집

## 4. Partitioning 전략

Polars는 **hash-based partitioning**을 사용한다. Radix partitioning이나 Grace Hash Join은 사용하지 않는다.

### Partition 수 결정

- `build_tables` 함수에서는 입력 `keys` vector의 길이를 그대로 partition 수로 사용한다 (`single_keys.rs:27-28`). 이 keys vector는 `split(array, n_threads)` 결과이므로, 결국 **partition 수 = thread 수**이다.
- `_set_partition_size()` 유틸리티를 사용하는 경우도 있다 (outer join 등).
- `hash_to_partition(hash, n_partitions)` 함수로 해시값을 partition에 매핑한다.

### Scatter 기반 Partitioning

`build_tables`에서의 핵심 최적화는 **scatter-based partitioning**이다 (`single_keys.rs:96-121`):
- 먼저 각 thread가 자신의 key portion의 partition 분포를 계산한다 (1차 pass).
- Prefix sum으로 global offset을 계산한다.
- 각 thread가 자신의 key를 해당 partition의 메모리 위치에 직접 scatter한다 (2차 pass).
- `SyncPtr`을 사용하여 서로 다른 offset에 lock-free로 동시 쓰기가 가능하다.

이 방식은 전통적인 "각 thread가 모든 key를 순회하며 자신의 partition만 처리"하는 방식보다 cache-friendly하다.

## 5. Parallelism (핵심 섹션)

### Rayon Thread Pool

Polars는 **Rayon** 기반의 data parallelism을 사용한다. 전역 thread pool `POOL`이 `polars-core/src/lib.rs`에 정의되어 있다:

```rust
// lib.rs:192
pub static THREAD_POOL: LazyLock<ThreadPool> = LazyLock::new(|| {
    ThreadPoolBuilder::new()
        .num_threads(
            std::env::var("POLARS_MAX_THREADS")
                .map(|s| s.parse::<usize>().unwrap())
                .unwrap_or_else(|_| std::thread::available_parallelism() ...)
        )
        .build()
        .expect("could not spawn threads")
});
```

- `POLARS_MAX_THREADS` 환경변수로 thread 수를 제어할 수 있다.
- `POOL.install(|| ...)` 패턴으로 Rayon의 thread pool에서 작업을 실행한다.
- `POOL.join(a, b)` 패턴으로 두 독립 작업을 fork-join으로 병렬 수행한다.

### 병렬 처리 구간별 분석

#### (1) Build Phase 병렬화

`build_tables` (`single_keys.rs:50-166`)에서 3단계 모두 `POOL.install()` 내에서 실행되며:

- **Stage 1 — Partition counting**: `keys.par_iter().with_max_len(1).map(...)` — 각 key portion이 독립적으로 partition 크기를 계산한다.
- **Stage 2 — Scatter**: `keys.into_par_iter().with_max_len(1).enumerate().for_each(...)` — 각 thread가 독립 offset에 lock-free scatter.
- **Stage 3 — Hash map build**: `(0..n_partitions).into_par_iter().with_max_len(1).map(...)` — 각 partition의 hash map을 독립적으로 구축.

`with_max_len(1)` 설정은 Rayon의 work-stealing이 각 iteration을 별도 task로 처리하도록 보장한다.

#### (2) Probe Phase 병렬화

Inner join probe (`single_keys_inner.rs:78-147`):
```rust
POOL.install(|| {
    let tuples = probe.into_par_iter().zip(offsets).map(|(probe, offset)| {
        // 각 thread가 자신의 probe chunk를 독립적으로 처리
        // hash_tbls는 immutable reference로 공유
        probe_inner(probe, hash_tbls, &mut results, local_offset, n_tables, swap_fn)
    }).collect::<Vec<_>>();
    // ... parallel materialization
});
```

- Build-side hash table은 immutable로 공유되므로 lock이 필요 없다.
- 각 thread가 자신의 probe partition만 처리하여 결과를 로컬 Vec에 수집한다.
- 결과 materialization도 `tuples.into_par_iter().zip(offsets).for_each(...)` 로 병렬화한다.

Left join probe (`single_keys_left.rs:146-192`):
```rust
POOL.install(move || {
    probe.into_par_iter().zip(offsets).map(move |(probe, offset)| {
        // 각 thread가 독립적으로 left/right 인덱스 쌍 생성
    }).collect()
});
```

Semi/anti join probe도 동일하게 `POOL.install(|| par_iter.collect())` 패턴을 사용한다 (`single_keys_semi_anti.rs:108, 124`).

#### (3) 결과 Materialization 병렬화

Inner join의 결과 병합은 **parallel memcpy 패턴**을 사용한다 (`single_keys_inner.rs:115-146`):
- 전체 크기와 각 chunk의 offset을 계산한다.
- 최종 벡터를 미리 할당하고, 각 thread가 `SyncPtr`을 통해 자신의 offset 위치에 직접 쓴다.
- `set_len`으로 length를 설정하여 불필요한 초기화를 피한다.

Left join의 결과 병합은 `flatten_par`를 사용한다 (`single_keys_left.rs:67-101`).

#### (4) DataFrame Materialization 병렬화

Join 인덱스가 결정된 후, 실제 DataFrame의 left/right 부분 구성도 `POOL.join`으로 병렬화한다:

```rust
// dispatch_left_right.rs:102-105
POOL.join(
    || materialize_left_join_idx_left(&left, left_idx.as_slice(), args),
    || materialize_left_join_idx_right(&right, right_idx.as_slice(), args),
)
```

Full outer join의 경우도 동일하다 (`hash_join/mod.rs:189-192`):
```rust
POOL.join(
    || unsafe { df_self.take_unchecked(join_tuples_left) },
    || unsafe { other.take_unchecked(join_tuples_right) },
)
```

#### (5) Hashing 병렬화

`_df_rows_to_hashes_threaded_vertical` (`vector_hasher.rs:480-497`) 함수는 여러 DataFrame partition에 대해 해싱을 병렬 수행한다:
```rust
let hashes = POOL.install(|| {
    keys.into_par_iter().map(|df| {
        columns_to_hashes(df, Some(hb), &mut hashes)?;
        Ok(UInt64Chunked::from_vec(..., hashes))
    }).collect::<PolarsResult<Vec<_>>>()
})?;
```

#### (6) 비병렬 구간

Full outer join의 probe phase는 **단일 thread**에서 수행된다. Hash table의 mutable state (tracker bool)를 수정해야 하므로 lock-free 병렬화가 불가능하다 (`single_keys_outer.rs:199-204`).

### Sort-Merge Join 최적화 (Performant Feature)

`#[cfg(feature = "performant")]`로 활성화되는 **sorted merge join** 최적화가 있다 (`sort_merge.rs`):
- 양쪽 키가 모두 정렬되어 있고 null이 없으면 `par_sorted_merge_inner_no_nulls` 또는 `par_sorted_merge_left`를 사용한다.
- 한쪽만 정렬되어 있으면 다른 쪽을 `arg_sort`로 정렬 후 merge join하고, 결과 인덱스를 `reverse_idx_map`으로 역매핑한다.
- Size factor (`POLARS_JOIN_SORT_FACTOR` 환경변수, 기본값 1.0)를 통해 sort-then-merge가 hash join보다 효율적인지 판단한다.
- Merge join 자체도 `_split_offsets`로 left side를 분할하여 `par_iter`로 병렬 처리한다.

### MIN_ELEMS_PER_THREAD

병렬화 threshold: `MIN_ELEMS_PER_THREAD = 128` (release 빌드 기준, debug에서는 1). 전체 key 수가 `2 * 128 = 256` 미만이면 단일 thread로 처리한다 (`single_keys.rs:14, 35`).

## 6. Memory Management

### Chunked Processing

Polars의 모든 데이터는 `ChunkedArray`로 관리되며, 각 chunk는 독립적인 Arrow Array이다. Join 시:

- `split(array, n_threads)` 함수로 ChunkedArray를 n개의 sub-ChunkedArray로 분할한다.
- Multi-chunk된 데이터는 `ChunkId` (chunk_index, array_index) 매핑을 통해 global index와 변환한다 (`general.rs:99-109`).
- 필요시 `rechunk_mut_par()`로 단일 contiguous chunk로 재조립한다 (`mod.rs:189`).

### Memory 최적화

- **Capacity pre-allocation**: probe 결과 벡터를 probe 크기만큼 미리 할당한다 (`single_keys_left.rs:157-158`).
- **IdxVec (Small Vec)**: build table의 value는 `IdxVec` (inline small vector)를 사용하여, unique key가 많은 경우 heap 할당을 줄인다 (`single_keys.rs:155` — `unitvec![idx]`).
- **Mmap-style slice**: 결과 인덱스를 복사 없이 `IdxCa::mmap_slice`로 ChunkedArray에 매핑한다 (`mod.rs:573`).
- **Avoid double initialization**: `SyncPtr` + `set_len` 패턴으로 결과 벡터를 초기화 없이 직접 쓴다.

### Spill-to-Disk

In-memory 엔진인 Polars의 기본 join 구현에는 **spill-to-disk 메커니즘이 없다**. 메모리 초과 시 OOM이 발생한다. 다만, Polars의 streaming/out-of-core 엔진(polars-stream/polars-pipe)에서는 별도의 메모리 관리가 존재하지만, 이 분석에서는 in-memory join에 집중한다.

## 7. Join Types 지원

`JoinType` enum (`args.rs:59-80`)에 정의된 모든 join type:

| Join Type | 구현 위치 | 병렬 Probe | Build Side |
|-----------|----------|-----------|-----------|
| **Inner** | `single_keys_inner.rs::hash_join_tuples_inner` | O (parallel) | shorter relation |
| **Left** | `single_keys_left.rs::hash_join_tuples_left` | O (parallel) | always right |
| **Right** | `dispatch_left_right.rs::right_join_from_series` | O (parallel) | left를 build, swap하여 left join으로 구현 |
| **Full (Outer)** | `single_keys_outer.rs::hash_join_tuples_outer` | X (single-threaded probe) | shorter relation |
| **Semi** | `single_keys_semi_anti.rs::hash_join_tuples_left_semi` | O (parallel) | right (PlHashSet) |
| **Anti** | `single_keys_semi_anti.rs::hash_join_tuples_left_anti` | O (parallel) | right (PlHashSet) |
| **Cross** | `cross_join.rs` | O (parallel) | N/A (cartesian product) |
| **AsOf** | `asof/` 디렉토리 | 별도 구현 | binary search 기반 |
| **IEJoin** | `iejoin/` 디렉토리 | 별도 구현 | inequality join |

### Right Join 구현

Right join은 left/right를 swap한 left join으로 구현된다 (`dispatch_left_right.rs:21-36`):
```rust
fn right_join_from_series(...) {
    args.maintain_order = args.maintain_order.flip();
    let (df_right, df_left) = materialize_left_join_from_series(
        right, left, s_right, s_left, &args, verbose, drop_names,
    )?;
    _finish_join(df_left, df_right, args.suffix)
}
```

### Multi-Key Join

다중 키 join 시 **row encoding**을 사용한다 (`mod.rs:347-352`):
- `prepare_keys_multiple` 함수에서 `encode_rows_vertical_par_unordered`로 여러 키를 하나의 binary representation으로 인코딩한다.
- Float 타입은 canonicalization (`to_canonical()`)을 거쳐 NaN 등의 비교 문제를 해결한다 (`mod.rs:641-643`).

### Join Validation

`JoinValidation` enum (`args.rs:328-341`)은 ManyToMany, ManyToOne, OneToMany, OneToOne 유효성 검사를 지원한다:
- Build phase에서 `validate_build`로 build table 크기를 검증한다.
- Probe phase 전에 `validate_probe`로 probe side의 uniqueness를 검증한다.
- Validation이 필요한 경우 sort-merge join 최적화는 건너뛴다 (`sort_merge.rs:230-231`).

## 8. Key References

### 핵심 소스 코드 경로

| 파일 경로 | 핵심 함수 | 역할 |
|-----------|----------|------|
| `crates/polars-ops/src/frame/join/hash_join/single_keys.rs` | `build_tables()` | Partition 기반 병렬 hash table build |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_inner.rs` | `probe_inner()`, `hash_join_tuples_inner()` | Inner join probe + parallel materialization |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_left.rs` | `hash_join_tuples_left()`, `flatten_left_join_ids()` | Left join probe + 결과 병합 |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_outer.rs` | `prepare_hashed_relation_threaded()`, `probe_outer()` | Outer join (single-threaded probe) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_semi_anti.rs` | `build_table_semi_anti()`, `semi_anti_impl()` | Semi/Anti join (HashSet 기반) |
| `crates/polars-ops/src/frame/join/hash_join/single_keys_dispatch.rs` | `SeriesJoin` trait, `group_join_inner()` | Type dispatch 및 데이터 분할 |
| `crates/polars-ops/src/frame/join/hash_join/sort_merge.rs` | `_sort_or_hash_inner()`, `par_sorted_merge_left()` | Sort-merge join 최적화 |
| `crates/polars-ops/src/frame/join/hash_join/mod.rs` | `JoinDispatch` trait, `det_hash_prone_order!` | Build side 결정 및 결과 DataFrame 구성 |
| `crates/polars-ops/src/frame/join/mod.rs` | `DataFrameJoinOps::_join_impl()` | Join 진입점, 단일/다중 키 분기 |
| `crates/polars-ops/src/frame/join/dispatch_left_right.rs` | `materialize_left_join_from_series()` | Left/Right join materialization |
| `crates/polars-ops/src/frame/join/general.rs` | `_finish_join()`, `_coalesce_full_join()` | 결과 DataFrame 병합 및 suffix 처리 |
| `crates/polars-ops/src/frame/join/args.rs` | `JoinArgs`, `JoinType`, `JoinValidation` | Join 인자 및 타입 정의 |
| `crates/polars-core/src/hashing/vector_hasher.rs` | `VecHash` trait, `numeric_vec_hash()` | 벡터화 해싱 |
| `crates/polars-core/src/hashing/mod.rs` | `_HASHMAP_INIT_SIZE` | 해시맵 초기 크기 상수 |
| `crates/polars-core/src/lib.rs` | `THREAD_POOL`, `POOL` | Rayon thread pool 정의 |

### 외부 의존성

- **hashbrown 0.16**: Swiss Table 구현체 (`Cargo.toml:61`)
- **rayon**: 데이터 병렬 처리 (`Cargo.toml`)
- **xxhash-rust (xxh3)**: Binary/String 해싱 (`vector_hasher.rs:8`)
- **ahash**: 정수형 해싱 (hashbrown 내부 기본 hasher)

### 참고 문헌 (코드 내 인용)

- CockroachDB Blog: "Vectorized Hash Joiner" — `vector_hasher.rs:19`에서 해시 결합 전략 참조
- aHash source: folded multiply 기법 — `vector_hasher.rs:15`에서 참조
