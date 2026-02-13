# Umbra / HyPer — Hash Join 분석

## 개요

HyPer와 Umbra는 독일 뮌헨 공과대학교(TUM)의 Thomas Neumann 교수 연구 그룹에서 개발한 학술 기반 관계형 데이터베이스 시스템이다. HyPer(2008~)는 순수 in-memory HTAP 시스템으로 시작했으며, Umbra(2018~)는 HyPer의 후속 시스템으로 SSD 기반 저장소를 지원하면서도 in-memory 수준의 성능을 달성한다. Umbra의 상용 버전은 2024년 CedarDB로 스핀오프되었다.

두 시스템 모두 **data-centric code generation** (컴파일 기반 쿼리 실행)과 **morsel-driven parallelism** (세밀한 병렬 스케줄링)을 핵심 기술로 사용하며, hash join은 이 두 기술이 결합되는 대표적인 연산이다.

> 주의: HyPer와 Umbra는 공개 소스 코드가 없으므로, 본 분석은 전적으로 학술 논문과 공식 블로그 포스트를 기반으로 한다.

---

## 1. Hash Table 구조

### HyPer의 Chained Hash Table with Tags

HyPer의 hash join은 **chained hash table**을 사용하며, 각 hash bucket에 **16-bit hash tag**를 포함하는 구조를 채택했다. 이 설계의 핵심은 64-bit 포인터 내에 tag를 내장하는 것이다:

- **하위 48 bits**: 실제 메모리 주소 (x86-64에서 48-bit virtual address space 활용)
- **상위 16 bits**: Bloom filter 역할을 하는 hash tag

Probe 시 tag를 먼저 확인하여 매칭되지 않는 경우 chain traversal 없이 즉시 건너뛸 수 있다. 이는 hash join에서 가장 빈번한 경우인 "매칭 파트너가 없는 경우"를 최적화한다. 포인터와 tag가 하나의 64-bit 값에 패킹되어 있으므로, **compare-and-swap (CAS) atomic instruction**으로 lock-free insertion이 가능하다 [1].

### Umbra/CedarDB의 Unchained Hash Table

Umbra의 후속 연구에서는 chained hash table의 한계를 극복하는 **unchained hash table** 설계를 제안했다 [7]. 이 설계는 chaining의 collision 처리 능력과 linear probing의 dense storage 장점을 결합한 하이브리드 접근법이다:

- **Pointer directory**: 상위 hash bits로 slot을 결정하고, 하위 bits로 Bloom filter tag를 확인
- **4-bit Bloom filter**: 포인터의 상위 16 bits에 내장되며, false-positive rate 1% 미만 달성
- **4KB lookup table**: 사전 계산된 Bloom tag를 저장하여, 단일 `and-not` instruction으로 tag 매칭 수행
- **Hot path 최적화**: 매칭이 없는 경우 단 **10개의 x86 instruction**으로 처리 완료

이 설계는 graph 쿼리에서 chained 방식 대비 최대 **16배 speedup**, TPC-H (100GB)에서 약 **6배 speedup** (HyPer/DuckDB 대비)을 달성했다 [7].

**참고 문헌:**
- [1] Leis et al., "Morsel-Driven Parallelism", SIGMOD 2014
- [7] Birler et al., "Simple, Efficient, and Robust Hash Tables for Join Processing", DaMoN 2024

---

## 2. Build Phase

### Compilation 기반 Tuple Materialization

HyPer와 Umbra는 모두 **data-centric code generation**을 사용하여 build phase 코드를 직접 기계어로 컴파일한다 [2]. 전통적인 Volcano 모델의 tuple-at-a-time 해석 실행과 달리, 컴파일된 코드는 operator 경계를 허물고 데이터 흐름 중심으로 코드를 생성한다.

Build phase는 다음과 같이 진행된다 [1]:

1. **Phase 1 - Local Materialization**: 각 worker thread가 자신의 NUMA 노드에 할당된 morsel들을 처리하며, build 측 relation을 스캔하고 필터링한 결과를 **thread-local storage area**에 적재한다. 이 storage area는 해당 thread가 위치한 NUMA 소켓에 로컬로 할당된다.

2. **Phase 2 - Hash Table Insertion**: 모든 morsel의 스캔이 완료된 후, Phase 1에서 정확한 tuple 수를 알 수 있으므로 **완벽한 크기의 global hash table**을 할당한다. 이후 각 thread가 자신의 로컬 storage area를 다시 스캔하며 hash table에 포인터를 삽입한다.

이러한 **two-phase build** 설계의 핵심 장점은:
- Hash table 크기를 정확히 알 수 있어 resizing이 불필요
- NUMA locality를 유지하면서 병렬 빌드 수행
- Lock-free CAS 기반 삽입으로 synchronization overhead 최소화

### Umbra/CedarDB의 개선된 Build Phase

Umbra/CedarDB에서는 build phase를 세 단계로 세분화했다 [7]:

1. **Local Buffering**: 각 thread가 build 측 row를 로컬 버퍼에 저장하여, 정확한 hash table 크기를 사전에 결정
2. **Parallel Insertion**: Lock-free `atomic_compare_exchange` 루프를 사용하여 동기화 병목 없이 병렬 삽입
3. **Read-only Probing**: 별도 단계로 분리 (아래 Probe Phase 참조)

**참고 문헌:**
- [1] Leis et al., SIGMOD 2014
- [2] Neumann, "Efficiently Compiling Efficient Query Plans for Modern Hardware", VLDB 2011
- [7] Birler et al., DaMoN 2024

---

## 3. Probe Phase

### Compiled Probe Code

Probe phase는 build phase 완료 후 실행되며, hash table이 read-only 상태이므로 **동기화가 전혀 필요하지 않다** [1]. 이는 probe 측이 일반적으로 build 측보다 훨씬 크기 때문에 중요한 성능 특성이다.

Probe 과정:
1. Probe 측 tuple의 join key에 대해 hash 값 계산
2. Hash 값의 상위 bits로 hash table의 bucket 위치 결정
3. **Tag-based filtering**: 하위 hash bits를 bucket에 내장된 Bloom filter tag와 비교하여 early rejection 수행
4. Tag가 매칭되는 경우에만 실제 key 비교를 수행하여 정확한 매칭 확인

Umbra의 unchained 설계에서는 이 hot path가 단 **10개의 x86 instruction**으로 최적화되었으며, false-positive rate가 1% 미만이므로 불필요한 메모리 접근을 극적으로 줄인다 [7].

### Dispatcher에 의한 NUMA-Aware Probe 스케줄링

Dispatcher는 probe 시에도 NUMA locality를 유지한다. Thread에게 해당 NUMA 소켓에 위치한 base relation의 morsel을 할당하여, cross-socket 메모리 접근을 최소화한다 [1].

**참고 문헌:**
- [1] Leis et al., SIGMOD 2014
- [7] Birler et al., DaMoN 2024

---

## 4. Partitioning 전략

### Radix Partitioning 실험

Bandle et al. [6]은 Umbra에서 radix hash join (multi-pass radix partitioning)을 통합하는 실험을 수행했다. Radix join은 합성 microbenchmark에서는 non-partitioned hash join보다 우수한 성능을 보이는 것으로 알려져 있었으나, 실제 시스템에서의 결과는 달랐다.

#### 핵심 발견 사항:

1. **Bloom Filter 기반 Semi-Join Reducer**: Radix join의 실용성을 높이기 위해 **register-blocked Bloom filter** 기반 semi-join reducer를 도입했다. 이는 selective 쿼리에서 radix join을 경쟁력 있게 만들었다.

2. **TPC-H 결과**: TPC-H의 총 59개 join 중 radix join이 눈에 띄는 개선을 가져온 것은 **단 1개**뿐이었다.

3. **최종 결론**: "code-generating database 내에서 radix join을 통합하는 것은 코드와 옵티마이저 복잡성 증가를 거의 정당화하지 못하며, 실제 워크로드 처리에는 권장하지 않는다."

### 기본 전략: Non-Partitioned Hash Join

따라서 Umbra는 기본적으로 **non-partitioned hash join**을 사용한다. Cache efficiency는 partitioning 대신 다음 방법으로 달성한다:
- Build phase의 local buffering으로 cache-friendly 접근 패턴 유지
- Bloom filter tag를 통한 early rejection으로 cache miss 감소
- Morsel 단위 처리로 working set을 cache에 맞춤

**참고 문헌:**
- [6] Bandle, Giceva, Neumann, "To Partition, or Not to Partition, That is the Join Question in a Real System", SIGMOD 2021

---

## 5. Parallelism — Morsel-Driven Parallelism (핵심 섹션)

### 개념과 동기

Morsel-driven parallelism은 Leis et al. [1]이 SIGMOD 2014에서 제안한 병렬 쿼리 실행 프레임워크로, 현대 many-core NUMA 아키텍처에서의 query evaluation을 위해 설계되었다. 이 논문은 데이터베이스 시스템의 병렬 처리 패러다임에 근본적인 영향을 미쳤다.

기존 접근법의 문제:
- **Plan-based parallelism**: 병렬도가 쿼리 계획 시점에 고정되어 runtime 적응이 불가
- **NUMA 무인식**: Cross-socket 메모리 접근으로 인한 성능 저하
- **Load balancing 부재**: Skewed 데이터 분포에서 특정 thread에 부하 집중

### Morsel의 정의

**Morsel**은 약 **100,000 tuples** 크기의 입력 데이터 조각이다 [1]. 이 크기는 다음을 고려하여 선택되었다:
- **너무 작으면**: Dispatcher overhead가 과도해짐
- **너무 크면**: 메모리 사용량 증가 및 load balancing 정밀도 저하
- 10,000 tuples 이상에서 실행 시간이 개선되는 것이 실험적으로 확인됨 [1]

각 morsel은 단일 NUMA 노드에 상주하며, 해당 노드의 "색상"을 가진다.

### Dispatcher 아키텍처

중앙 **Dispatcher**는 morsel-driven 실행의 핵심 구성 요소이다:

1. **Fine-grained Runtime Scheduling**: 병렬도가 계획에 고정되지 않고, 실행 중 탄력적으로 변경 가능
2. **NUMA-Aware 할당**: Thread에게 같은 NUMA 노드에 위치한 morsel을 우선 할당
3. **Elastic Resource Management**: 새로 도착하는 쿼리에 대응하여 리소스를 동적으로 재배분
4. **Morsel 속도 모니터링**: 서로 다른 morsel의 실행 속도에 반응하여 스케줄링 조정

Dispatcher는 쿼리 내의 **pipeline들을 순차적으로 실행**하되, 각 pipeline 내에서는 morsel 단위 병렬 처리를 수행한다.

### NUMA-Aware Scheduling 알고리즘

Thread는 특정 코어에 **pinning**되며, 해당 NUMA 노드에 할당된다 [1]:

1. Thread가 작업을 요청하면, Dispatcher는 **같은 NUMA 노드의 morsel을 우선 할당**
2. 동일 노드에 가용 morsel이 없으면, **다른 NUMA 노드의 morsel을 "reluctantly" 처리** (work stealing의 일종)
3. 테이블 데이터는 primary key/foreign key 해싱으로 NUMA 메모리 뱅크에 반균등 분배

이 접근법은 cross-socket 메모리 접근을 최소화하면서도 load balancing을 유지한다. 일부 쿼리에서는 NUMA-awareness가 큰 차이를 만들지만, 모든 쿼리에서 그런 것은 아니다 [1].

### Hash Join에서의 Morsel-Driven Parallelism

Hash join은 **pipeline breaker**이므로, morsel-driven 실행에서 특별한 처리가 필요하다:

#### Build Pipeline:
1. Worker thread들이 build relation의 morsel을 병렬로 처리
2. 각 thread는 NUMA-local storage에 필터링된 tuple을 materialization
3. 모든 morsel 처리 완료 후, 정확한 tuple 수를 기반으로 global hash table 할당
4. 각 thread가 자신의 local storage를 스캔하며 lock-free CAS로 hash table에 삽입
5. **Synchronization barrier**: 모든 build 완료 후에만 probe 시작 가능

#### Probe Pipeline:
1. Build 완료 후, Dispatcher가 probe relation의 morsel을 할당
2. 각 thread가 NUMA-local morsel을 가져와 hash table을 probe
3. Hash table은 read-only이므로 동기화 불필요
4. 출력 tuple을 다음 pipeline의 입력으로 전달

### Work Stealing과 Elasticity

Morsel 기반 접근법은 암묵적으로 **dynamic work distribution**을 지원한다 [1]:
- Thread가 자신의 morsel을 빨리 처리하면 즉시 다음 morsel을 요청
- 느린 thread의 부하가 자연스럽게 다른 thread로 분산
- 쿼리 실행 중 새로운 쿼리가 도착하면, 일부 thread를 새 쿼리에 재할당 가능

### 성능 결과

TPC-H와 SSB 벤치마크에서 [1]:
- **32 코어에서 평균 30배 이상의 speedup** 달성
- Nehalem EX 및 Sandy Bridge EP 시스템에서 검증
- NUMA-aware 버전이 non-NUMA 버전 및 Vectorwise를 상회

**참고 문헌:**
- [1] Leis, Boncz, Kemper, Neumann, "Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age", SIGMOD 2014

---

## 6. Memory Management

### HyPer: Pure In-Memory

HyPer는 순수 in-memory 시스템으로, 모든 데이터를 메인 메모리에 상주시킨다. Hash join의 hash table도 메모리에 직접 할당되며, spill-to-disk 메커니즘은 지원하지 않는다.

### Umbra: Variable-Size Pages와 Buffer Manager

Umbra는 HyPer의 가장 큰 제약 (전체 데이터가 메모리에 적합해야 함)을 해결하기 위해 혁신적인 buffer manager를 도입했다 [3]:

#### Variable-Size Pages:
- 페이지 크기가 **64KB에서 전체 buffer pool 크기까지** 2의 거듭제곱으로 증가하는 **exponential size class** 시스템
- 각 size class마다 전체 buffer pool 크기의 virtual memory region을 예약
- 관계(relation)는 B+ tree로 저장되며, internal node는 64KB, leaf node는 가변 크기 페이지 사용

#### Virtual Memory 기법:
- **Virtual-to-physical address mapping**: 연속된 가상 주소가 물리적으로는 분산될 수 있어 fragmentation 해결
- **`pread`**: 디스크에서 buffer frame으로 페이지 로드
- **`pwrite`**: 변경된 페이지를 디스크에 기록
- **`madvise(MADV_DONTNEED)`**: 물리 메모리를 OS에 반환하여 즉시 재사용 가능

#### Pointer Swizzling:
- 전역 hash table 대신 **pointer swizzling**을 사용하여 page 참조를 직접 메모리 주소로 변환
- Locking overhead를 회피하고 page access의 효율성을 극대화

이러한 설계로 Umbra는 cached working set에 대해 in-memory 시스템에 필적하는 성능을 달성하면서, DRAM보다 저렴한 SSD를 활용할 수 있다 [3].

**참고 문헌:**
- [3] Neumann, Freitag, "Umbra: A Disk-Based System with In-Memory Performance", CIDR 2020

---

## 7. Join Types 지원

논문들에서 확인된 Umbra의 join 지원 범위:

### Binary Hash Join
- **Inner join**: 기본 hash join 연산 [1, 7]
- **Semi join**: Bloom filter 기반 semi-join reducer로 최적화 [6]
- **Anti join**: semi join의 역연산으로 지원 가능

### Worst-Case Optimal Join (WCOJ)

Freitag et al. [5]는 Umbra에 **hash trie 기반 WCOJ**를 통합했다:
- 여러 입력 relation에 대해 **hash trie index**를 빌드하고 multi-way join 수행
- Binary join 대비 중간 결과 폭발을 방지하여, 특정 쿼리에서 **최대 100배 성능 향상**
- 하이브리드 옵티마이저가 binary join과 WCOJ 중 최적을 자동 선택
- TPC-H와 JOB에서는 binary join이 항상 선택됨 (growing join이 없으므로)

### Diamond Hardened Join

Birler et al. [8]은 n:m join에서 발생하는 **diamond problem**을 해결하는 프레임워크를 제안했다:
- Join operator를 **Lookup**과 **Expand** suboperator로 분리
- Query optimizer가 자유롭게 재배치하여 불필요한 중간 결과 생성 방지
- Bloom filter를 통한 sideway information passing으로 join ordering robustness 향상
- CE 벤치마크에서 최대 **500배 성능 향상**, TPC-H에서도 우수한 성능 유지

**참고 문헌:**
- [5] Freitag et al., "Adopting Worst-Case Optimal Joins in Relational Database Systems", VLDB 2020
- [6] Bandle et al., SIGMOD 2021
- [8] Birler, Kemper, Neumann, "Robust Join Processing with Diamond Hardened Joins", VLDB 2024

---

## 8. HyPer vs Umbra 차이점

### 진화 경로: HyPer → Umbra → CedarDB

| 구분 | HyPer (2008~) | Umbra (2018~) | CedarDB (2024~) |
|------|---------------|---------------|------------------|
| **저장소** | Pure in-memory | SSD + in-memory buffer | 상용 SSD 기반 |
| **컴파일** | LLVM 직접 사용 | Custom Umbra IR + adaptive | Umbra 기반 |
| **상태** | Tableau에 인수 (2016) | TUM 연구 프로젝트 | 상용 스핀오프 |

### 컴파일 전략의 진화

**HyPer** [2]:
- LLVM IR을 직접 생성하고 LLVM의 -O3 최적화 파이프라인으로 컴파일
- 컴파일 시간이 쿼리 실행 시간의 최대 **29배**까지 소요되는 문제 발생 [4]
- Data-centric code generation으로 operator 경계를 허물어 hand-written C++ 수준의 성능 달성

**Umbra** [4]:
- **Flying Start**: Custom IR에서 x86 기계어를 단일 패스로 직접 생성. Stack space reuse, register allocation 등 최적화 포함
- **Adaptive Compilation**: 짧은 쿼리는 bytecode interpretation, 긴 쿼리는 LLVM 기반 최적화 컴파일. 실행 중 전환 가능
- **State Machine 모델**: 파이프라인을 state machine으로 조직하여 쿼리를 suspend/resume 가능. 이는 스케줄링과 I/O 처리에 유리
- 결과: 작은 데이터셋에서 DuckDB, PostgreSQL보다도 빠른 latency, 큰 데이터셋에서 HyPer와 동등한 throughput

### Hash Table 진화

- **HyPer**: Chained hash table with 16-bit tags [1]
- **Umbra**: Unchained hash table with 4-bit Bloom filter, 10 instruction hot path [7]
- **Diamond Hardened Join**: Lookup/Expand 분리로 skew와 diamond problem 대응 [8]

### 메모리 관리의 진화

- **HyPer**: 전체 데이터가 메모리에 적합해야 함. 메모리 부족 시 처리 불가
- **Umbra**: Variable-size page buffer manager로 SSD를 투명하게 활용. Virtual memory 기법으로 in-memory 수준 성능 유지 [3]

### Join 알고리즘의 진화

- **HyPer**: 기본 binary hash join
- **Umbra**: Binary hash join + WCOJ 하이브리드 [5], radix join 통합 실험 (권장하지 않음) [6], Diamond Hardened Join [8]

**참고 문헌:**
- [2] Neumann, VLDB 2011
- [3] Neumann, Freitag, CIDR 2020
- [4] Kersten, Leis, Neumann, "Tidy Tuples and Flying Start", VLDB Journal 2021
- [5] Freitag et al., VLDB 2020
- [7] Birler et al., DaMoN 2024
- [8] Birler et al., VLDB 2024

---

## 9. Key References

### 핵심 논문

1. **[1]** Viktor Leis, Peter Boncz, Alfons Kemper, Thomas Neumann. *"Morsel-Driven Parallelism: A NUMA-Aware Query Evaluation Framework for the Many-Core Age"*. SIGMOD 2014.
   - URL: https://dl.acm.org/doi/10.1145/2588555.2610507
   - PDF: https://15721.courses.cs.cmu.edu/spring2016/papers/p743-leis.pdf

2. **[2]** Thomas Neumann. *"Efficiently Compiling Efficient Query Plans for Modern Hardware"*. PVLDB, Vol. 4, No. 9, 2011.
   - URL: https://dl.acm.org/doi/10.14778/2002938.2002940
   - PDF: https://www.vldb.org/pvldb/vol4/p539-neumann.pdf

3. **[3]** Thomas Neumann, Michael J. Freitag. *"Umbra: A Disk-Based System with In-Memory Performance"*. CIDR 2020.
   - URL: https://www.semanticscholar.org/paper/88a0ce733f712e742733362623aa0a27710a5b9f
   - PDF: https://db.in.tum.de/~freitag/papers/p29-neumann-cidr20.pdf

4. **[4]** Timo Kersten, Viktor Leis, Thomas Neumann. *"Tidy Tuples and Flying Start: Fast Compilation and Fast Execution of Relational Queries in Umbra"*. The VLDB Journal, Vol. 30, pp. 883-905, 2021.
   - URL: https://link.springer.com/article/10.1007/s00778-020-00643-4

5. **[5]** Michael Freitag, Maximilian Bandle, Tobias Schmidt, Alfons Kemper, Thomas Neumann. *"Adopting Worst-Case Optimal Joins in Relational Database Systems"*. PVLDB, Vol. 13, No. 11, pp. 1891-1904, 2020.
   - URL: https://dl.acm.org/doi/10.14778/3407790.3407797
   - PDF: https://www.vldb.org/pvldb/vol13/p1891-freitag.pdf

6. **[6]** Maximilian Bandle, Jana Giceva, Thomas Neumann. *"To Partition, or Not to Partition, That is the Join Question in a Real System"*. SIGMOD 2021.
   - URL: https://dl.acm.org/doi/10.1145/3448016.3452831
   - PDF: https://db.in.tum.de/~bandle/papers/bandle-partitionVsNonPartition.pdf

7. **[7]** Altan Birler, Tobias Schmidt, Philipp Fent, Thomas Neumann. *"Simple, Efficient, and Robust Hash Tables for Join Processing"*. DaMoN 2024, Santiago, Chile.
   - URL: https://dl.acm.org/doi/10.1145/3662010.3663442
   - PDF: https://db.in.tum.de/~birler/papers/hashtable.pdf
   - Blog: https://cedardb.com/blog/simple_efficient_hash_tables/

8. **[8]** Altan Birler, Alfons Kemper, Thomas Neumann. *"Robust Join Processing with Diamond Hardened Joins"*. PVLDB, Vol. 17, No. 11, pp. 3215-3228, 2024.
   - URL: https://dl.acm.org/doi/10.14778/3681954.3681995
   - PDF: https://db.in.tum.de/people/sites/birler/papers/diamond.pdf

9. **[9]** Tobias Maier, Peter Sanders, Roman Dementiev. *"Concurrent Hash Tables: Fast and General(?!)"*. PPoPP 2016; ACM Transactions on Parallel Computing, Vol. 5, No. 4, 2019.
   - URL: https://dl.acm.org/doi/10.1145/3309206
   - arXiv: https://arxiv.org/abs/1601.04017

10. **[10]** Thomas Neumann. *"Evolution of a Compiling Query Engine"*. PVLDB, Vol. 14, No. 12, pp. 3207-3210, 2021.
    - URL: http://www.vldb.org/pvldb/vol14/p3207-neumann.pdf

### 추가 자료

- Umbra 공식 사이트: https://umbra-db.com/
- CedarDB 공식 사이트: https://cedardb.com/
- Database of Databases — Umbra: https://dbdb.io/db/umbra
