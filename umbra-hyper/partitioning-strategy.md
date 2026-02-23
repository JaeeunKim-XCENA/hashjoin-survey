# Umbra/HyPer Partitioning 전략 심층 분석

## 요약

Umbra/HyPer의 partitioning 전략은 한 문장으로 요약할 수 있다: **"partitioning하지 않는 것이 최선이다."** Bandle et al. (SIGMOD 2021)은 Umbra에서 radix hash join을 실제로 통합하는 대규모 실험을 수행한 후, code-generating database 시스템에서 radix join의 복잡성 대비 실질적 이득이 극히 제한적이라는 결론을 내렸다. TPC-H의 총 59개 join 중 radix join이 유의미한 개선을 보인 것은 **단 1건**에 불과했다.

따라서 Umbra는 기본적으로 **non-partitioned hash join**을 사용하며, cache efficiency는 다음 기법들로 달성한다:
- Build phase의 local buffering과 morsel 단위 처리로 working set을 cache에 적합하게 유지
- Bloom filter tag 기반 early rejection으로 불필요한 cache miss 방지
- Morsel-driven parallelism을 통한 NUMA-aware 데이터 접근

이 분석 문서에서는 Umbra에서 실험된 radix partitioning의 구체적 내용, 그 결과가 왜 부정적이었는지, 그리고 같은 "radix"라는 이름을 사용하면서도 완전히 다른 목적으로 활용하는 DuckDB와의 차이를 다룬다.

> 주의: HyPer와 Umbra는 공개 소스 코드가 없으므로, 본 분석은 전적으로 학술 논문을 기반으로 한다.

---

## Radix Partitioning 개요

### Classic Radix Join의 원래 목적

Radix join은 Boncz, Manegold, Kersten이 제안한 파티셔닝 기반 hash join 알고리즘이다 [1, 2]. 핵심 아이디어는 hash table의 build와 probe가 모두 **CPU cache 내부에서** 이루어지도록, 양쪽 relation을 미리 cache-sized 파티션으로 분할하는 것이다.

동기: 전통적인 non-partitioned hash join에서 hash table이 cache보다 크면, probe 과정에서 거의 모든 hash table 접근이 cache miss를 유발한다. 특히 대규모 relation에서는 **TLB (Translation Lookaside Buffer) miss**가 성능 병목이 된다. TLB는 가상 주소를 물리 주소로 변환하는 캐시로, 엔트리 수가 제한적이기 때문에 넓은 메모리 범위에 걸쳐 random access하면 TLB miss가 급증한다.

Radix partitioning의 목표:
1. 파티셔닝 후 각 파티션의 크기가 L2 또는 L1 cache에 fit하도록 만든다
2. 파티셔닝 과정 자체에서도 TLB miss가 발생하지 않도록 pass를 나눈다
3. Build와 probe가 cache-resident 데이터에 대해서만 수행되어 cache miss가 거의 없다

### Radix Partitioning의 메커니즘

Radix partitioning은 hash 값의 특정 비트 범위를 사용하여 tuple의 파티션 소속을 결정한다. `radix_bits = B`이면 `2^B`개의 파티션이 생성되며, 각 tuple은 hash 값의 해당 비트에 따라 정확히 하나의 파티션에 배치된다.

```
hash value:  [b63 b62 ... b4 b3 b2 b1 b0]
                          ^^^^
                          radix bits (예: 3 bits → 8 파티션)
```

핵심 속성: radix bits를 B에서 B+K로 확장하면, 기존의 각 파티션이 정확히 `2^K`개의 하위 파티션으로 분할된다. 이 **계층적 분할 (hierarchical decomposition)** 특성이 radix 방식의 가장 중요한 장점이며, multi-pass partitioning과 dynamic repartitioning을 가능하게 한다.

---

## Multi-Pass Radix Partitioning

### TLB 문제와 Multi-Pass의 필요성

Single-pass radix partitioning에서 `2^B`개 파티션으로 동시에 scatter하면, 각 파티션이 서로 다른 메모리 페이지에 위치할 수 있다. `2^B`가 TLB 엔트리 수를 초과하면 TLB thrashing이 발생하여 파티셔닝 자체의 비용이 커진다.

이를 해결하기 위해 Boncz et al.은 **multi-pass radix partitioning**을 제안했다 [1, 2]:

**Pass 1**: hash 값의 상위 `B1` 비트로 `2^B1`개 파티션 생성
- `2^B1`이 TLB 엔트리 수 이내이므로 TLB miss 없음
- 각 파티션의 크기 = 전체 데이터 / `2^B1`

**Pass 2**: 각 파티션 내에서 다음 `B2` 비트로 `2^B2`개 하위 파티션 생성
- 이미 파티션이 작아졌으므로 working set이 cache에 fit
- 최종 파티션 수 = `2^(B1+B2)`

예시 (Boncz et al.의 전형적 설정):
- TLB 엔트리 = 64 → B1 = 6 (Pass 1에서 64개 파티션)
- L2 cache = 256KB → B2를 조정하여 각 최종 파티션이 256KB 이내

이 방식으로 **파티셔닝 과정의 TLB miss**와 **join 수행 시의 cache miss**를 동시에 최소화한다.

### Radix Join의 전체 흐름

```
Input R (Build)         Input S (Probe)
    │                       │
    ▼                       ▼
[Pass 1: partition R]   [Pass 1: partition S]
    │                       │
    ▼                       ▼
[Pass 2: sub-partition] [Pass 2: sub-partition]
    │                       │
    ▼                       ▼
  R_0, R_1, ..., R_N     S_0, S_1, ..., S_N
    │                       │
    └───────┬───────────────┘
            ▼
  For each i: build HT(R_i), probe with S_i
  (각 파티션이 cache에 fit → cache-resident join)
```

---

## Build-Side Partitioning

### Umbra의 실제 Build 전략: Non-Partitioned

Umbra는 기본적으로 build side를 파티셔닝하지 않는다 [3, 4]. Build phase는 다음과 같이 진행된다:

1. **Local Materialization**: 각 worker thread가 morsel 단위로 build relation을 스캔하며, NUMA-local storage에 tuple을 적재한다 [3].

2. **Global Hash Table 할당**: 모든 morsel 처리가 완료되면 정확한 tuple 수를 알 수 있으므로, resizing이 불필요한 정확한 크기의 global hash table을 한 번에 할당한다 [3].

3. **Lock-free Insertion**: 각 thread가 자신의 local storage를 스캔하며 compare-and-swap (CAS) atomic instruction으로 hash table에 포인터를 삽입한다 [3].

이 설계에서 build data는 파티셔닝되지 않으며, **하나의 monolithic hash table**이 생성된다. Cache efficiency는 파티셔닝이 아닌 다른 메커니즘으로 확보한다:

- **Morsel 크기 (~100,000 tuples)**: 각 thread의 working set이 적절한 크기로 유지됨
- **Local buffering**: NUMA-local 메모리에서 순차적으로 쓰기 → cache-friendly
- **Bloom filter tag**: Hash table probe 시 매칭이 없는 경우를 tag로 즉시 rejection → 불필요한 chain traversal 및 cache miss 방지

### Radix Join 통합 시의 Build-Side Partitioning

Bandle et al. [4]이 Umbra에서 radix join을 실험할 때는, build side에 multi-pass radix partitioning을 적용했다. 이 실험에서 build side 파티셔닝은 classic radix join의 방식을 따른다:

1. Build relation 전체를 radix bits에 따라 파티션으로 분배
2. 각 파티션 내부에서 소형 hash table 구축
3. 파티션 크기가 cache에 fit하므로 build 과정에서 cache miss 최소화

그러나 실험 결과, 이 파티셔닝의 이점이 실제 워크로드에서는 미미했다. 그 이유는 다음 절에서 상세히 다룬다.

---

## Probe-Side Partitioning

### Non-Partitioned Probe (기본 전략)

Umbra의 기본 probe는 파티셔닝 없이 수행된다 [3, 5]:

1. Build 완료 후 hash table은 read-only 상태가 되어 동기화가 전혀 필요 없다
2. Dispatcher가 probe relation의 morsel을 NUMA-aware하게 worker thread에 할당
3. 각 thread가 morsel의 tuple들에 대해 hash table을 probe
4. Bloom filter tag로 early rejection → hot path가 단 10개 x86 instruction으로 완료 [5]

### Radix Join 실험에서의 Probe-Side Partitioning

Radix join 실험에서는 probe side도 build side와 동일한 radix bits로 파티셔닝한 후, 파티션 쌍(R_i, S_i)별로 join을 수행한다 [4]. 그러나 probe side 파티셔닝에는 추가 비용이 발생한다:

- **Materialization 비용**: Probe 데이터를 파티셔닝하려면 먼저 전체를 materialization해야 한다
- **Pipeline break**: Code-generating 시스템에서 probe side의 파티셔닝은 pipeline을 끊는다. Probe가 원래 push-based pipeline의 일부로 실행되는데, 파티셔닝을 추가하면 별도의 pipeline breaker가 된다
- **추가 메모리**: Probe data의 파티셔닝된 복사본을 위한 메모리가 필요

### Semi-Join Reducer로 Probe 비용 절감

Bandle et al. [4]은 radix join의 실용성을 높이기 위해 **register-blocked Bloom filter** 기반 semi-join reducer를 도입했다. 이는 build side의 key들로 Bloom filter를 구축한 후, probe side에서 확실히 매칭이 없는 tuple들을 사전에 제거하는 기법이다.

Semi-join reducer의 효과:
- Selective한 쿼리(join 결과가 작은 경우)에서 probe data의 크기를 크게 줄임
- 파티셔닝할 데이터 양이 감소하여 radix join의 overhead를 상쇄
- TPC-H의 일부 쿼리에서 radix join을 경쟁력 있게 만듦

그러나 이 최적화를 적용하더라도, TPC-H 59개 join 중 radix join이 유의미한 개선을 보인 것은 단 1건이었다 [4].

---

## Morsel-Driven Parallelism과 Partitioning

### Morsel-Driven Parallelism 개요

Morsel-driven parallelism [3]은 HyPer/Umbra의 병렬 쿼리 실행 프레임워크이다. 데이터를 약 100,000 tuple 크기의 morsel로 나누고, 중앙 Dispatcher가 worker thread에게 morsel을 NUMA-aware하게 할당한다. 이 프레임워크는 partitioning 전략과 직접적으로 상호작용한다.

### Non-Partitioned Hash Join에서의 Morsel 활용

현재 Umbra의 기본 전략인 non-partitioned hash join에서 morsel-driven parallelism은 다음과 같이 동작한다 [3]:

**Build Pipeline:**
1. 각 worker thread가 build relation의 morsel을 할당받아 처리
2. Thread-local storage에 tuple materialization (NUMA-local)
3. 모든 morsel 완료 후 synchronization barrier
4. Global hash table 할당 및 lock-free CAS로 병렬 삽입

**Probe Pipeline:**
1. Build 완료 후 Dispatcher가 probe relation의 morsel을 할당
2. 각 thread가 NUMA-local morsel을 가져와 read-only hash table probe
3. 동기화 불필요 → 완전 병렬 수행
4. 출력 tuple을 다음 pipeline으로 전달

이 구조에서 partitioning이 없기 때문에:
- Pipeline이 깔끔하게 유지됨 (build → barrier → probe)
- 추가 materialization 단계가 없음
- NUMA locality는 morsel 할당 정책으로 확보

### Radix Join과 Morsel의 충돌

Bandle et al. [4]이 발견한 핵심 문제 중 하나는 radix join이 morsel-driven parallelism 및 code-generating 실행 모델과 잘 맞지 않는다는 점이다:

1. **Pipeline 구조 변경**: Radix join을 도입하면 build side와 probe side 모두에 파티셔닝 단계가 추가되어 pipeline 구조가 복잡해진다. 기존의 `build → barrier → probe` 구조가 `build → partition → barrier → probe → partition → partition-pair join`으로 변경된다.

2. **Code generation 복잡성**: 파티셔닝 단계는 별도의 compiled code를 필요로 하며, 옵티마이저가 radix join과 non-partitioned join 중 선택하는 로직이 추가되어야 한다.

3. **Load balancing**: Skewed 데이터에서 파티션 크기가 불균등하면, 특정 파티션 쌍의 join이 오래 걸려 다른 thread들이 대기하게 된다. Morsel-driven의 fine-grained work stealing과 달리, partition-pair 단위의 작업 분배는 granularity가 거칠다.

### 최종 결론: Partitioning보다 Non-Partitioned Join이 우월

Bandle et al. [4]의 실험 결과를 종합하면:

- **Microbenchmark (합성 데이터)**: Radix join이 non-partitioned join보다 cache miss가 적어 throughput이 높음. 이는 기존 연구 결과와 일치.
- **TPC-H (실제 워크로드)**: 59개 join 중 radix join이 유의미하게 빠른 것은 **단 1건**. 대부분의 join에서 non-partitioned join이 동등하거나 우월.
- **이유**: 실제 워크로드에서는 (1) join selectivity가 높아 작은 hash table이 cache에 자연스럽게 fit하거나, (2) 파티셔닝 overhead가 cache miss 절감 효과를 상쇄하거나, (3) Bloom filter tag가 이미 cache miss를 충분히 줄임.

논문의 원문 결론: *"We came to the conclusion that integrating radix join into a code-generating database is not justified by the additional code and optimizer complexity, and do not recommend it for real workload processing."* [4]

---

## DuckDB와의 비교

### 같은 이름, 다른 목적

DuckDB와 Umbra/HyPer 모두 "radix partitioning"이라는 용어를 사용하지만, 목적과 사용 방식이 근본적으로 다르다.

| 구분 | Umbra/HyPer (실험) | DuckDB |
|------|---------------------|--------|
| **목적** | TLB/cache locality 최적화 (classic radix join) | 메모리 관리 (grace hash join / external hash join) |
| **기본 전략** | Non-partitioned hash join (radix join은 기각) | In-memory는 non-partitioned, external은 radix partitioning |
| **파티셔닝 대상** | Build + Probe 양쪽 모두 | Build side 사전 파티셔닝 + Probe side는 probe와 동시 수행 |
| **Multi-pass** | TLB miss 방지를 위한 multi-pass scatter | 사용하지 않음 (single-pass streaming append) |
| **Histogram** | 연속 배열 배치를 위해 histogram + prefix sum 필요 | 불필요 (chunked storage에 동적 append) |
| **파티션 수 결정** | Cache 크기와 TLB 엔트리 수 기반 | 초기 16개 고정, 메모리 부족 시 동적 증가 |
| **Repartitioning** | 해당 없음 (고정 파티션 수) | Radix bits 증가로 계층적 세분화 (hash 재계산 불필요) |
| **최종 채택 여부** | 기각 (non-partitioned 유지) | External join에서 핵심적으로 사용 |

### 목적의 차이: Cache Optimization vs Memory Management

**Umbra에서의 radix join (실험):**
Classic radix join [1, 2]의 목적을 따른다. 양쪽 relation을 cache-sized 파티션으로 분할하여 hash table build와 probe가 전부 L1/L2 cache 안에서 이루어지게 한다. 목표는 **cache miss 최소화**이다.

**DuckDB의 radix partitioning:**
Grace hash join의 메모리 관리 메커니즘이다. 전체 데이터가 메모리에 들어가지 않을 때, 파티션 단위로 disk에 spill한 후 한 번에 하나의 파티션만 메모리에 올려서 build/probe를 수행한다. 목표는 **메모리 초과 상황 대응**이다.

DuckDB가 radix 방식을 채택한 이유는 TLB 최적화가 아니라 **repartitioning의 용이성** 때문이다. `hash % N` 방식으로 파티셔닝하면 파티션 수를 변경할 때 모든 row를 rehash해야 하지만, radix 방식은 상위 비트를 더 많이 읽기만 하면 기존 파티션이 정확히 세분화된다. 이미 row에 저장된 hash 값을 재계산할 필요가 없다.

### In-Memory 동작의 차이

**Umbra:**
- In-memory에서 non-partitioned hash join을 사용 (기본 전략)
- Radix join은 실험적으로 통합했으나 이점이 없어 기각
- Cache efficiency는 Bloom filter tag, morsel 단위 처리, compiled code로 확보

**DuckDB:**
- In-memory에서 파티셔닝을 전혀 활용하지 않음
- `Unpartition()`으로 초기 16개 파티션을 하나로 합쳐서 단일 hash table 구축
- Cache efficiency는 vectorized execution (2048-tuple batch)으로 확보

두 시스템 모두 **in-memory hash join에서는 partitioning이 불필요하다**는 결론을 공유한다. 차이점은 Umbra가 이를 논문으로 실증한 반면, DuckDB는 애초에 in-memory radix join을 시도하지 않고 external join의 메모리 관리 용도로만 radix를 사용한다는 점이다.

### External/Spill 전략의 차이

**Umbra:**
- HyPer는 순수 in-memory 시스템으로 spill-to-disk 미지원 [6]
- Umbra는 variable-size page buffer manager로 SSD를 투명하게 활용하지만 [6], hash join 차원의 explicit spill 메커니즘(grace hash join)에 대한 상세 내용은 논문에서 별도로 다루지 않음
- Partitioning 기반 spill보다는 buffer manager 수준의 메모리 관리에 의존

**DuckDB:**
- External hash join 시 radix partitioning으로 build data를 disk에 spill
- Probe data는 별도 파티셔닝 패스 없이 probe와 동시에 spill (`ProbeAndSpill`)
- 파티션 단위로 순차적으로 메모리에 올려서 build/probe 수행
- 메모리 부족 시 radix bits를 증가시켜 동적 repartitioning

### Bloom Filter 활용의 차이

**Umbra:**
- Hash table 자체에 Bloom filter tag를 내장 (HyPer: 16-bit tag, Umbra/CedarDB: 4-bit Bloom filter) [3, 5]
- Probe 시 tag를 먼저 확인하여 매칭이 없는 경우 즉시 rejection
- Radix join 실험에서는 별도의 register-blocked Bloom filter를 semi-join reducer로 활용 [4]

**DuckDB:**
- Radix partitioning은 Bloom filter와 독립적으로 동작
- Probe-side에서 `RadixPartitioning::Select()`로 active/spill 파티션을 분리하는 데 사용

### 종합 평가

Bandle et al. [4]의 연구는 데이터베이스 커뮤니티에 중요한 시사점을 제공한다. Microbenchmark에서 radix join의 우수성을 보여주는 연구가 다수 존재하지만, 실제 시스템에 통합했을 때의 결과는 다르다. 그 이유는:

1. **실제 워크로드의 특성**: TPC-H 등 실제 워크로드에서 join의 build side가 충분히 작아 hash table이 자연스럽게 cache에 fit하는 경우가 대부분이다
2. **Code generation의 효과**: Compiled code가 이미 interpretation overhead를 제거하므로, cache miss의 상대적 비중이 microbenchmark에서만큼 크지 않다
3. **Tag-based filtering**: Bloom filter tag가 cache miss를 효과적으로 줄여, radix partitioning의 cache locality 이점이 상당 부분 상쇄된다
4. **파티셔닝 overhead**: 양쪽 relation의 파티셔닝 비용(materialization, 추가 메모리, pipeline break)이 cache miss 절감 효과를 초과한다

반면, DuckDB의 radix partitioning은 cache 최적화와 무관하게 **메모리 관리**라는 명확한 문제를 해결하므로, 그 가치가 분명하다. External join에서는 disk I/O가 dominant cost이므로 TLB miss 같은 미세한 최적화는 중요하지 않으며, 계층적 분할 가능성이라는 radix의 핵심 속성이 dynamic repartitioning에 직접적으로 활용된다.

---

## Key References

### 핵심 논문

1. **[1]** Peter Boncz, Stefan Manegold, Martin Kersten. *"Database Architecture Optimized for the New Bottleneck: Memory Access"*. VLDB 1999.
   - Classic radix join의 원 논문. TLB/cache 최적화를 위한 radix partitioning 기법 제안.
   - URL: https://www.vldb.org/conf/1999/P5.pdf

2. **[2]** Stefan Manegold, Peter Boncz, Martin Kersten. *"Optimizing Main-Memory Join on Modern Hardware"*. IEEE TKDE, Vol. 14, No. 4, 2002.
   - Radix join의 확장 및 hardware-conscious 최적화 분석.

3. **[3]** Viktor Leis, Peter Boncz, Alfons Kemper, Thomas Neumann. *"Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age"*. SIGMOD 2014.
   - Morsel-driven parallelism 제안. Hash join의 병렬 build/probe 전략, NUMA-aware scheduling 상세.
   - URL: https://dl.acm.org/doi/10.1145/2588555.2610507
   - PDF: https://15721.courses.cs.cmu.edu/spring2016/papers/p743-leis.pdf

4. **[4]** Maximilian Bandle, Jana Giceva, Thomas Neumann. *"To Partition, or Not to Partition, That is the Join Question in a Real System"*. SIGMOD 2021.
   - Umbra에서 radix join 통합 실험의 종합적 결과. Register-blocked Bloom filter 기반 semi-join reducer 제안. **본 분석의 핵심 출처.**
   - URL: https://dl.acm.org/doi/10.1145/3448016.3452831
   - PDF: https://db.in.tum.de/~bandle/papers/bandle-partitionVsNonPartition.pdf

5. **[5]** Altan Birler, Tobias Schmidt, Philipp Fent, Thomas Neumann. *"Simple, Efficient, and Robust Hash Tables for Join Processing"*. DaMoN 2024.
   - Umbra/CedarDB의 unchained hash table 설계. 4-bit Bloom filter tag, 10 instruction hot path.
   - URL: https://dl.acm.org/doi/10.1145/3662010.3663442
   - PDF: https://db.in.tum.de/~birler/papers/hashtable.pdf

6. **[6]** Thomas Neumann, Michael J. Freitag. *"Umbra: A Disk-Based System with In-Memory Performance"*. CIDR 2020.
   - Umbra의 buffer manager와 variable-size page 설계. HyPer에서 Umbra로의 진화.
   - URL: https://www.semanticscholar.org/paper/88a0ce733f712e742733362623aa0a27710a5b9f
   - PDF: https://db.in.tum.de/~freitag/papers/p29-neumann-cidr20.pdf

### DuckDB 참고 (비교 분석용)

7. Kuiper et al. *"Saving Private Hash Join: How to Implement an External Hash Join within Limited Memory"*. VLDB 2024.
   - DuckDB의 external hash join 구현. Radix partitioning을 메모리 관리 목적으로 활용.
