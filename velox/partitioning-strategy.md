# Velox Hash Join Partitioning 전략 심층 분석

## 요약

Velox의 hash join partitioning은 **memory arbitration 기반의 on-demand spill** 메커니즘이다. DuckDB가 build 완료 후 전체 크기를 확인하여 repartitioning 여부를 결정하는 것과 달리, Velox는 **memory arbitrator가 메모리 압박을 감지하면 그 시점에 spill을 trigger**하는 방식이다. 파티셔닝은 hash 값의 특정 bit range를 사용하며, 메모리 부족이 반복되면 bit range를 이동(shift)하여 recursive spilling을 수행한다.

핵심 특성:
- **On-demand spill**: 사전 파티셔닝이 아닌, memory arbitration에 의해 필요 시 spill 발동
- **Hash bit range 기반 파티셔닝**: `HashBitRange(startBit, endBit)`로 hash 값의 특정 bit 구간을 사용하여 파티션 결정
- **Recursive spilling**: spill된 파티션 복원 시 메모리에 맞지 않으면 다음 bit range로 이동하여 재귀적으로 세분화
- **Build-Probe 대응 spill**: build side에서 spill된 파티션에 대해 probe side도 동일 파티션으로 spill하여 정합성 보장
- **최대 4단계 spill level**: `SpillPartitionId::kMaxSpillLevel = 3`으로, 각 level에서 3비트(최대 8파티션)를 사용하면 이론적 최대 파티션 수는 8^4 = 4096

---

## 1. Partitioning 개요

### 1.1 파티션 수 결정

Velox의 파티션 수는 `SpillConfig`의 두 가지 파라미터로 결정된다:

- **`startPartitionBit`**: hash 값에서 파티션 계산을 시작하는 bit 위치 (기본값: 48)
- **`numPartitionBits`**: 파티션 결정에 사용할 bit 수 (기본값: 3)

파티션 수 = `2^numPartitionBits`이며, 기본 설정에서는 **2^3 = 8개 파티션**이다.

이 값들은 `DriverCtx::makeSpillConfig()`에서 `QueryConfig`으로부터 읽어온다 (`Driver.cpp:165-166`):
```cpp
queryConfig.spillStartPartitionBit(),   // 기본값: 48
queryConfig.spillNumPartitionBits(),    // 기본값: 3
```

### 1.2 Hash Bit Range 기반 파티션 분배

`HashBitRange` 클래스(`HashBitRange.h`)가 hash 값에서 파티션 번호를 추출하는 핵심 유틸리티이다:

```cpp
class HashBitRange {
  int32_t partition(uint64_t hash) const {
    return (hash >> begin_) & fieldMask_;
  }
  int32_t numPartitions() const {
    return 1 << numBits();  // 2^(end_ - begin_)
  }
};
```

예를 들어 `HashBitRange(48, 51)`이면 hash 값의 bit 48~50(3비트)을 추출하여 0~7 범위의 파티션 번호를 산출한다.

### 1.3 SpillPartitionId -- 계층적 파티션 식별자

`SpillPartitionId`(`Spill.h:277-362`)는 recursive spilling을 지원하기 위한 계층적 파티션 ID이다. 32비트 정수에 다음과 같이 인코딩된다:

```
비트 레이아웃 (LSB에서 MSB 방향):
  [0-2]   : 1st level 파티션 번호 (0~7)
  [3-5]   : 2nd level 파티션 번호
  [6-8]   : 3rd level 파티션 번호
  [9-11]  : 4th level 파티션 번호
  [12-28] : 미사용
  [29-31] : 현재 spill level (0~3)
```

각 level에서 `kNumPartitionBits = 3`비트(최대 8개 파티션)를 사용하며, `kMaxSpillLevel = 3`으로 최대 4단계까지 recursive spilling이 가능하다.

---

## 2. Build-Side Partitioning

### 2.1 Spill Trigger 메커니즘

Velox의 build-side 파티셔닝은 **사전에 수행되지 않는다**. `HashBuild::addInput()`이 처리되는 동안 모든 데이터는 `RowContainer`에 축적되며, 메모리 부족이 감지될 때만 spill이 발동된다.

Spill trigger는 두 가지 경로로 발생한다:

**경로 1 -- `ensureInputFits()` (`HashBuild.cpp:552-635`)**

입력 처리 전에 필요한 메모리를 예측하고 reservation을 시도한다. Reservation 실패 시 `Operator::ReclaimableSectionGuard`를 통해 memory arbitrator가 이 operator를 spill 대상으로 선택할 수 있도록 한다:

```cpp
void HashBuild::ensureInputFits(RowVectorPtr& input) {
  // ...메모리 계산...
  {
    Operator::ReclaimableSectionGuard guard(this);
    if (pool()->maybeReserve(targetIncrementBytes)) {
      if (spiller_->spillTriggered()) {
        pool()->release();  // spill이 발생하면 reservation 불필요
      }
      return;
    }
  }
}
```

**경로 2 -- `reclaim()` (`HashBuild.cpp:1257-1333`)**

Memory arbitrator가 직접 호출한다. 모든 peer build operator의 spiller를 사용하여 RowContainer 데이터를 disk에 spill한다:

```cpp
void HashBuild::reclaim(...) {
  // 모든 peer operator의 spiller 수집
  std::vector<HashBuildSpiller*> spillers;
  for (auto* op : operators) {
    HashBuild* buildOp = static_cast<HashBuild*>(op);
    spillers.push_back(buildOp->spiller_.get());
  }
  // 병렬 spill 수행
  spillHashJoinTable(spillers, config);
  // 모든 operator의 table 클리어
  for (auto* op : operators) {
    HashBuild* buildOp = static_cast<HashBuild*>(op);
    buildOp->table_->clear(true);
    buildOp->pool()->release();
  }
}
```

### 2.2 `HashBuildSpiller`의 파티셔닝 동작

`HashBuildSpiller`(`HashBuild.h:405-446`)는 `SpillerBase`를 상속하며, `RowContainer`의 모든 행을 hash partition별로 분류하여 spill한다.

**`fillSpillRuns()` (`Spiller.cpp:88-144`)** -- 핵심 파티셔닝 로직:

```cpp
bool SpillerBase::fillSpillRuns(RowContainerIterator* iterator) {
  constexpr int32_t kHashBatchSize = 4096;
  std::vector<uint64_t> hashes(kHashBatchSize);
  std::vector<char*> rows(kHashBatchSize);
  const bool isSinglePartition = bits_.numPartitions() == 1;

  for (;;) {
    const auto numRows = container_->listRows(iterator, rows.size(), rows.data());
    if (numRows == 0) break;

    // Hash 계산
    if (!isSinglePartition) {
      for (auto i = 0; i < container_->keyTypes().size(); ++i) {
        container_->hash(i, rowSet, i > 0, hashes.data());
      }
    }

    // 파티션별 분류
    for (auto i = 0; i < numRows; ++i) {
      const auto partitionNum = isSinglePartition ? 0 : bits_.partition(hashes[i]);
      auto& spillRun = createOrGetSpillRun(SpillPartitionId(partitionNum));
      spillRun.rows.push_back(rows[i]);
      spillRun.numBytes += container_->rowSize(rows[i]);
    }
  }
}
```

`kHashBatchSize = 4096` 단위로 RowContainer의 행들을 순회하며, 각 행의 hash 값에서 `HashBitRange::partition()`으로 파티션 번호를 추출하여 `SpillRun`에 분류한다.

### 2.3 Spill 이후 신규 입력의 처리

일단 spill이 trigger되면(`spillTriggered_ = true`), 이후 도착하는 모든 build 입력은 `spillInput()` (`HashBuild.cpp:637-677`)을 통해 즉시 해당 파티션으로 spill된다:

```cpp
void HashBuild::spillInput(const RowVectorPtr& input) {
  if (!canSpill() || spiller_ == nullptr || !spiller_->spillTriggered() || ...) {
    return;  // spill이 trigger되지 않았으면 무시
  }
  computeSpillPartitions(input);  // 각 row의 파티션 번호 계산
  // 파티션별로 분류하여 spill
  for (uint32_t partition = 0; partition < numSpillInputs_.size(); ++partition) {
    spillPartition(partition, numInputs, spillInputIndicesBuffers_[partition], input);
  }
  activeRows_.updateBounds();  // spill된 row들은 activeRows에서 제외
}
```

`computeSpillPartitions()` (`HashBuild.cpp:712-730`)는 `VectorHasher::hash()`로 hash 값을 계산한 후, `spiller_->hashBits().partition(hash)`로 파티션 번호를 산출한다.

**주목할 점**: spill trigger 후에는 **모든 파티션**의 데이터가 spill된다. Velox는 DuckDB처럼 "active partition"과 "spill partition"을 구분하지 않고, build side에서는 전체 RowContainer를 spill한 후 table을 clear한다. 이후 입력은 RowContainer에 저장되지 않고 직접 spill file로 전달된다.

### 2.4 `ensureTableFits()` -- Hash Table Build 전 메모리 확보

모든 build driver의 데이터가 수집된 후 hash table을 구축하기 전에, `ensureTableFits()` (`HashBuild.cpp:934-975`)가 호출되어 hash table에 필요한 메모리를 확보한다:

```cpp
void HashBuild::ensureTableFits(uint64_t numRows) {
  const uint64_t memoryBytesToReserve = table_->estimateHashTableSize(numRows) * 1.1;
  {
    Operator::ReclaimableSectionGuard guard(this);
    if (pool()->maybeReserve(memoryBytesToReserve)) {
      if (spiller_->spillTriggered()) {
        pool()->release();
      }
      return;
    }
  }
}
```

1.1x 여유를 두고 hash table 크기를 예측한다. Reservation 실패 시 memory arbitrator에 의해 spill이 발생할 수 있다.

---

## 3. Probe-Side Partitioning

### 3.1 Probe 입력의 파티셔닝 설정

Build side에서 spill이 발생한 경우, probe side도 대응하는 파티션의 입력을 spill해야 한다. `HashProbe::maybeSetupInputSpiller()` (`HashProbe.cpp:234-278`)에서 이를 설정한다:

```cpp
void HashProbe::maybeSetupInputSpiller(const SpillPartitionIdSet& spillPartitionIds) {
  spillInputPartitionIds_ = spillPartitionIds;
  if (spillInputPartitionIds_.empty()) return;

  const auto bitOffset = partitionBitOffset(
      *spillInputPartitionIds_.begin(),
      spillConfig()->startPartitionBit,
      spillConfig()->numPartitionBits);

  inputSpiller_ = std::make_unique<NoRowContainerSpiller>(
      probeType_, restoringPartitionId_,
      HashBitRange(bitOffset, bitOffset + spillConfig()->numPartitionBits),
      spillConfig(), spillStats_.get());

  // Build side에서 spill된 파티션 ID를 probe spiller에도 설정
  inputSpiller_->setPartitionsSpilled(spillInputPartitionIds_);

  // SpillPartitionFunction으로 vectorized 파티셔닝 수행
  spillPartitionFunction_ = std::make_unique<SpillPartitionFunction>(
      SpillPartitionIdLookup(spillInputPartitionIds_,
          spillConfig()->startPartitionBit, spillConfig()->numPartitionBits),
      probeType_, keyChannels_);
}
```

`NoRowContainerSpiller`는 RowContainer 없이 직접 벡터 데이터를 spill하는 spiller이다. Probe side에서는 build side처럼 RowContainer에 축적하지 않고, 입력 벡터를 직접 파티션별로 spill file에 기록한다.

### 3.2 Probe 입력의 Spill 처리

`HashProbe::spillInput()` (`HashProbe.cpp:561-604`)에서 probe 입력을 파티셔닝한다:

```cpp
void HashProbe::spillInput(RowVectorPtr& input) {
  const auto numInputRows = input->size();
  prepareInputIndicesBuffers(input->size(), inputSpiller_->state().spilledPartitionIdSet());
  spillPartitionFunction_->partition(*input, spillPartitions_);

  vector_size_t numNonSpillingInput = 0;
  for (auto row = 0; row < numInputRows; ++row) {
    const auto& partitionId = spillPartitions_[row];
    if (!inputSpiller_->state().isPartitionSpilled(partitionId)) {
      rawNonSpillInputIndicesBuffer_[numNonSpillingInput++] = row;
      continue;  // spill 대상이 아닌 행은 probe에 사용
    }
    rawSpillInputIndicesBuffers_.at(partitionId)[numSpillInputs_.at(partitionId)++] = row;
  }

  // 파티션별 spill
  for (const auto& [partitionId, numRows] : numSpillInputs_) {
    if (numRows == 0) continue;
    inputSpiller_->spill(partitionId, wrap(numRows, spillInputIndicesBuffers_.at(partitionId), input));
  }

  // 결과: spill되지 않은 행만 남은 input으로 대체
  if (numNonSpillingInput == 0) { input = nullptr; }
  else { input = wrap(numNonSpillingInput, nonSpillInputIndicesBuffer_, input); }
}
```

이 과정은 DuckDB의 `ProbeAndSpill()`과 유사하게, probe와 spill이 동시에 수행된다:
- Build side에서 spill되지 않은 파티션의 행 -> 즉시 probe에 사용
- Build side에서 spill된 파티션의 행 -> 대응하는 spill file에 기록

### 3.3 SpillPartitionFunction -- Vectorized 파티셔닝

`SpillPartitionFunction`(`Spill.h:434-453`)은 `SpillPartitionIdLookup`을 사용하여 벡터 단위로 빠르게 파티셔닝을 수행한다:

```cpp
class SpillPartitionFunction {
  void partition(const RowVector& input, std::vector<SpillPartitionId>& partitionIds) {
    // VectorHasher로 hash 계산 후, lookup table로 파티션 ID 매핑
  }
};
```

`SpillPartitionIdLookup`(`Spill.h:399-429`)은 hash bit 구간을 인덱스로 하는 lookup 배열을 미리 생성하여, recursive spilling에서 다단계 bit 범위를 가진 파티션 ID도 빠르게 조회할 수 있도록 한다.

---

## 4. Spill-to-Disk 메커니즘

### 4.1 전체 Spill 복원 사이클

Build-Probe의 spill/restore 사이클은 `HashJoinBridge`를 중심으로 조율된다:

```
[1단계] Build Pipeline 처리
  │  모든 build driver가 RowContainer에 데이터 축적
  │  메모리 부족 시 → spill trigger → 전체 RowContainer를 파티션별로 spill
  │
  ▼
[2단계] Hash Table Build + Probe
  │  Build: spill되지 않은 데이터로 hash table 구축 (또는 spill trigger 시 빈 테이블)
  │  HashJoinBridge::setHashTable(table, spillPartitionSet, ...)
  │  Probe: 입력을 spill/non-spill로 분류하며 probe 수행
  │
  ▼
[3단계] Probe 완료 후 Spill Restore
  │  HashJoinBridge::probeFinished()
  │    → spillPartitionSet_에서 다음 파티션 선택
  │    → SpillPartition::split(numBuilders)로 shard 분배
  │    → restoringSpillShards_에 저장
  │
  ▼
[4단계] Shard별 병렬 Restore
  │  각 build driver가 HashJoinBridge::spillInputOrFuture()로 shard 획득
  │  → setupSpillInput() → setupTable() + setupSpiller(spillPartition)
  │  → processSpillInput(): spill file에서 읽어 addInput() 호출
  │    → 메모리에 맞으면: hash table build 완료
  │    → 메모리에 안 맞으면: recursive spilling (다음 bit range 사용)
  │
  ▼
[5단계] 복원된 파티션에 대해 probe → [3단계]로 반복
```

### 4.2 SpillPartition Split -- 병렬 복원

`SpillPartition::split(numShards)` (`Spill.h:495`)는 하나의 spill 파티션을 여러 shard로 나누어 build driver들이 병렬로 복원할 수 있게 한다. `HashJoinBridge::probeFinished()` (`HashJoinBridge.cpp:320-366`)에서 다음 파티션을 선택하고 split한다:

```cpp
void HashJoinBridge::probeFinished(bool restart) {
  if (spillPartitionSet_.hasNext()) {
    buildResult_.reset();
    auto nextSpillPartition = spillPartitionSet_.next();
    restoringSpillPartitionId_ = nextSpillPartition.id();
    restoringSpillShards_ = nextSpillPartition.split(numBuilders_);
    VELOX_CHECK_EQ(restoringSpillShards_.size(), numBuilders_);
  } else {
    buildResult_.reset();  // 모든 파티션 처리 완료
  }
}
```

### 4.3 Recursive Spilling

`setupSpiller()` (`HashBuild.cpp:283-344`)에서 spill 파티션을 복원할 때, bit range를 이전 level의 끝 지점에서 시작하여 recursive spilling을 가능하게 한다:

```cpp
void HashBuild::setupSpiller(SpillPartition* spillPartition) {
  const auto* config = spillConfig();
  uint8_t startPartitionBit = config->startPartitionBit;

  if (spillPartition != nullptr) {
    // 이전 spill level의 bit offset + numPartitionBits가 새로운 시작점
    const auto numPartitionBits = config->numPartitionBits;
    startPartitionBit =
        partitionBitOffset(spillPartition->id(), startPartitionBit, numPartitionBits)
        + numPartitionBits;

    // 최대 spill level 초과 여부 확인
    if (config->exceedSpillLevelLimit(startPartitionBit)) {
      LOG(WARNING) << "Exceeded spill level limit: " << config->maxSpillLevel;
      exceededMaxSpillLevelLimit_ = true;
      return;  // spilling 비활성화 → 메모리 부족 시 쿼리 실패
    }
  }

  spiller_ = std::make_unique<HashBuildSpiller>(
      joinType_, restoringPartitionId_, table_->rows(), spillType_,
      HashBitRange(startPartitionBit, startPartitionBit + config->numPartitionBits),
      config, spillStats_.get());
}
```

**Bit range 진행 예시** (numPartitionBits=3):

| Spill Level | startPartitionBit | endPartitionBit | Hash Bit 범위 | 파티션 수 |
|-------------|-------------------|-----------------|---------------|-----------|
| 0 (초기)    | 48                | 51              | bit 48~50     | 8         |
| 1           | 51                | 54              | bit 51~53     | 8         |
| 2           | 54                | 57              | bit 54~56     | 8         |
| 3 (최대)    | 57                | 60              | bit 57~59     | 8         |

`partitionBitOffset()` (`Spill.cpp:932-936`) 함수가 주어진 SpillPartitionId의 현재 spill level에 맞는 bit offset을 계산한다:

```cpp
uint8_t partitionBitOffset(
    const SpillPartitionId& id,
    uint8_t startPartitionBitOffset,
    uint8_t numPartitionBits) {
  return startPartitionBitOffset + numPartitionBits * id.spillLevel();
}
```

### 4.4 IterableSpillPartitionSet -- 파티션 순서 관리

`IterableSpillPartitionSet`(`Spill.h:547-577`)은 recursive spilling에서 파티션들의 처리 순서를 관리한다. `SpillPartitionId::operator<`의 비교 규칙에 따라:

- 같은 부모의 자식 파티션들은 파티션 번호 순서로 정렬
- 다른 level의 파티션은 level-by-level로 비교
- 더 얕은 level의 파티션이 앞에 위치 (단, 자식 파티션은 부모 다음에 그룹핑)

예: `p_0 < p_1 < p_2_0 < p_2_1 < p_2_2 < p_2_3 < p_3`

이 순서는 관련 파티션들이 함께 처리되도록 보장하면서, recursive spilling으로 생긴 자식 파티션들이 부모 파티션 바로 뒤에 삽입되게 한다.

### 4.5 Probed Flag 보존

Right/Full join에서는 build side 행의 probe 여부를 추적하는 probed flag가 있다. Spill 시에도 이 flag가 보존되어야 한다. `HashBuild::setupSpiller()`에서 `spillType_`에 boolean 컬럼을 추가하고 (`hashJoinTableSpillType()`, `HashJoinBridge.cpp:472-483`), `HashBuildSpiller::extractSpill()`에서 probed flag를 추출하여 spill 데이터에 포함시킨다:

```cpp
void HashBuildSpiller::extractSpill(folly::Range<char**> rows, RowVectorPtr& resultPtr) {
  // ... 일반 컬럼 추출 ...
  if (spillProbeFlag_) {
    container_->extractProbedFlags(
        rows.data(), rows.size(), false, false, result->childAt(types.size()));
  }
}
```

복원 시 `HashBuild::addInput()`에서 spill 입력의 probed flag를 읽어 `RowContainer::setProbedFlag()`로 복원한다.

### 4.6 Hash Table Spill from Bridge

Build가 완료되고 probe가 시작되기 전, hash table이 이미 구축된 상태에서도 memory arbitration에 의해 spill이 발생할 수 있다. 이 경우 `HashJoinBridge::reclaim()` (`HashJoinBridge.cpp:72-92`)이 호출되어, `tableSpillFunc_`를 통해 hash table을 직접 spill한다:

```cpp
void HashJoinBridge::reclaim() {
  if (tableSpillFunc_ == nullptr) return;
  if (!buildResult_.has_value() || buildResult_->table == nullptr ||
      buildResult_->table->numDistinct() == 0) return;

  auto spillPartitionSet = tableSpillFunc_(buildResult_->table);
  buildResult_->table->clear(true);
  appendSpilledHashTablePartitionsLocked(std::move(spillPartitionSet));
}
```

이는 "build는 완료했지만 아직 probe가 시작되지 않은" 시점에서만 동작한다 (`probeStarted_ == false` 조건).

---

## 5. DuckDB와의 비교

| 항목 | Velox | DuckDB |
|------|-------|--------|
| **파티셔닝 시점** | Spill trigger 시 (on-demand) | Build 시 항상 16개 파티션으로 streaming 파티셔닝 |
| **초기 파티션 수** | 설정 기반 (기본 8개, `2^numPartitionBits`) | 고정 16개 (`INITIAL_RADIX_BITS=4`) |
| **메모리 부족 대응** | Recursive spilling (다음 bit range 사용) | Repartitioning (radix bits 증가, 예: 16->128) |
| **In-memory join** | 파티셔닝 불필요 (단일 hash table) | `Unpartition()`으로 16개를 하나로 합침 |
| **Hash bit 사용** | 중간 bit range (기본 bit 48~50) | 상위 bit (MSB 쪽) |
| **Repartitioning** | 없음 (다른 bit range 사용) | hash 재계산 없이 bit 추가로 세분화 |
| **Probe-side spill** | Build에서 spill된 파티션만 대응 spill | `ProbeAndSpill()`로 active/spill 동시 분류 |
| **Spill trigger** | Memory arbitrator (query-level) | 데이터 크기 vs 메모리 비교 (operator-level) |
| **병렬 restore** | SpillPartition::split()으로 shard별 병렬 | 파티션별 순차 build-probe |
| **최대 파티션 계층** | 4 level (kMaxSpillLevel=3) | radix bits 증가 (MAX_RADIX_BITS=12) |

핵심적 차이:
1. **DuckDB는 sink 단계에서 항상 파티셔닝을 수행**(INITIAL_RADIX_BITS=4, 16개 파티션)하지만, in-memory join 시 `Unpartition()`으로 다시 하나로 합쳐 단일 hash table을 사용한다. 즉 in-memory join에서 파티셔닝은 실질적 의미가 없다. Velox는 메모리 부족 시에만 파티셔닝이 활성화되므로, **두 엔진 모두 in-memory join에서는 파티셔닝 없이 동작**한다는 점에서 유사하다.
2. **DuckDB는 repartitioning**(기존 파티션 세분화)을 사용하지만, Velox는 **recursive spilling**(다른 hash bit range 사용)으로 접근한다. DuckDB의 방식은 기존 데이터를 읽어 새 파티션에 재배치하는 반면, Velox는 spill된 파티션을 복원할 때 새로운 bit range로 spill하는 방식이다.
3. **Spill trigger 메커니즘이 근본적으로 다르다.** DuckDB는 build 완료 후 전체 크기를 확인하여 external join 여부를 결정하지만, Velox는 memory arbitrator가 runtime에 메모리 압박을 감지하여 임의 시점에 spill을 trigger한다. 이는 Velox가 다중 쿼리 환경에서 전체 시스템의 메모리를 관리하는 설계 철학을 반영한다.

---

## 6. Key References

### 소스 코드 경로 및 주요 함수

| 파일 | 주요 함수/클래스 | 역할 |
|------|------------------|------|
| `velox/exec/HashBitRange.h` | `HashBitRange::partition()`, `numPartitions()` | Hash bit range 기반 파티션 번호 추출 |
| `velox/exec/Spill.h` | `SpillPartitionId` | 계층적 파티션 ID (recursive spilling 지원) |
| `velox/exec/Spill.h` | `SpillPartition`, `SpillPartition::split()` | Spill 파티션 데이터 및 shard 분배 |
| `velox/exec/Spill.h` | `SpillPartitionIdLookup`, `SpillPartitionFunction` | Vectorized 파티셔닝 (probe side) |
| `velox/exec/Spill.h` | `IterableSpillPartitionSet` | Recursive spilling 파티션 순서 관리 |
| `velox/exec/Spill.h` | `SpillState` | Spill 파티션 상태 관리 및 파일 기록 |
| `velox/exec/Spill.cpp` | `SpillPartitionId::SpillPartitionId(parent, num)` | 자식 SpillPartitionId 생성 (recursive) |
| `velox/exec/Spill.cpp` | `partitionBitOffset()` | Spill level별 bit offset 계산 |
| `velox/exec/Spill.cpp` | `SpillPartitionIdLookup::SpillPartitionIdLookup()` | 다단계 파티션 lookup 테이블 생성 |
| `velox/exec/Spiller.h` | `SpillerBase`, `HashBuildSpiller`, `NoRowContainerSpiller` | Spiller 계층 구조 |
| `velox/exec/Spiller.cpp` | `SpillerBase::fillSpillRuns()` | RowContainer -> 파티션별 SpillRun 분류 |
| `velox/exec/Spiller.cpp` | `SpillerBase::runSpill()`, `writeSpill()` | 파티션별 spill 파일 기록 (병렬) |
| `velox/exec/Spiller.cpp` | `SpillerBase::finishSpill()` | Spill 완료 후 SpillPartitionSet 생성 |
| `velox/exec/HashBuild.h/cpp` | `HashBuild::setupSpiller()` | Spiller 설정 (recursive spill bit range 계산 포함) |
| `velox/exec/HashBuild.cpp` | `HashBuild::spillInput()`, `computeSpillPartitions()` | Build 입력의 파티셔닝 및 spill |
| `velox/exec/HashBuild.cpp` | `HashBuild::ensureInputFits()`, `ensureTableFits()` | 메모리 reservation 및 spill trigger |
| `velox/exec/HashBuild.cpp` | `HashBuild::reclaim()` | Memory arbitration에 의한 spill 수행 |
| `velox/exec/HashBuild.cpp` | `HashBuild::setupSpillInput()`, `processSpillInput()` | Spill 파티션 복원 및 재처리 |
| `velox/exec/HashProbe.cpp` | `HashProbe::maybeSetupInputSpiller()` | Probe side spiller 설정 |
| `velox/exec/HashProbe.cpp` | `HashProbe::spillInput()` | Probe 입력의 파티셔닝 및 spill |
| `velox/exec/HashProbe.cpp` | `HashProbe::maybeSetupSpillInputReader()` | Spill된 probe 데이터 복원 설정 |
| `velox/exec/HashProbe.cpp` | `HashProbe::prepareForSpillRestore()` | Spill 복원을 위한 상태 리셋 |
| `velox/exec/HashJoinBridge.h/cpp` | `HashJoinBridge::probeFinished()` | Probe 완료 후 다음 spill 파티션 선택 및 shard 분배 |
| `velox/exec/HashJoinBridge.cpp` | `HashJoinBridge::reclaim()` | Bridge 단계에서의 hash table spill |
| `velox/exec/HashJoinBridge.cpp` | `spillHashJoinTable()` (두 오버로드) | Hash table 병렬 spill 유틸리티 |

### 논문 및 참고 자료

- **Pedro Pedreira et al., "Velox: Meta's Unified Execution Engine"**, VLDB 2022. Velox의 전체 아키텍처, memory arbitration 기반의 spill 설계를 기술.
- **Velox GitHub Repository**: https://github.com/facebookincubator/velox -- 본 분석의 모든 코드 참조 출처.
