# Acero Hash Join Probe Side Streaming Analysis

## 분석 목표
Apache Arrow Acero의 Swiss Hash Join에서 **probe side가 streaming인지 확인**하고, batches가 어떻게 처리되는지 추적하기.

---

## 1. 핵심 발견

### 1.1 Probe Side는 준-Streaming (Semi-Streaming)

**결론**: Acero의 probe side는 **완전한 streaming이 아니라, 조건부 streaming** 구조를 가짐.

#### Streaming 특성:
- 각 probe batch가 도착할 때마다 **즉시 처리 가능** (hash table이 준비되면)
- Batch 단위로 incremental하게 결과 생성 가능
- 다운스트림 노드에 결과를 **즉시** 전달 가능

#### 파이프라인 차단 특성:
- **Build phase가 완료될 때까지 probe 불가**
- Probe batches가 도착해도 hash table이 준비되지 않으면 **accumulation queue에 저장**
- Hash table 준비 후 **batch group으로 일괄 processing**

---

## 2. Probe Side 처리 흐름

### 2.1 코드 흐름 (hash_join_node.cc)

#### InputReceived 메소드 (라인 902-926)
```cpp
Status InputReceived(ExecNode* input, ExecBatch batch) override {
    auto scope = TraceInputReceived(batch);
    size_t thread_index = plan_->query_context()->GetThreadIndex();
    int side = (input == inputs_[0]) ? 0 : 1;  // side==0: probe, side==1: build

    if (side == 0) {
        ARROW_RETURN_NOT_OK(OnProbeSideBatch(thread_index, std::move(batch)));
    } else {
        ARROW_RETURN_NOT_OK(OnBuildSideBatch(thread_index, std::move(batch)));
    }
    // ...
}
```

**특징**: 각 배치가 도착할 때마다 즉시 호출됨 (streaming 특성)

#### OnProbeSideBatch 메소드 (라인 823-842)
```cpp
Status OnProbeSideBatch(size_t thread_index, ExecBatch batch) {
    {
        std::lock_guard<std::mutex> guard(probe_side_mutex_);
        if (!bloom_filters_ready_) {
            probe_accumulator_.InsertBatch(std::move(batch));
            return Status::OK();  // 조건 1: Bloom filter 준비 안됨
        }
    }
    RETURN_NOT_OK(pushdown_context_.FilterSingleBatch(thread_index, &batch));

    {
        std::lock_guard<std::mutex> guard(probe_side_mutex_);
        if (!hash_table_ready_) {
            probe_accumulator_.InsertBatch(std::move(batch));
            return Status::OK();  // 조건 2: Hash table 준비 안됨 → 큐에 저장
        }
    }
    RETURN_NOT_OK(impl_->ProbeSingleBatch(thread_index, std::move(batch)));
    return Status::OK();  // Hash table 준비됨 → 즉시 처리
}
```

**세 가지 경로**:
1. **Bloom filter 미준비**: batch → `probe_accumulator_` 큐에 저장
2. **Hash table 미준비**: batch → `probe_accumulator_` 큐에 저장  (파이프라인 차단)
3. **Hash table 준비됨**: `impl_->ProbeSingleBatch()` 직접 호출 (streaming)

---

### 2.2 JoinProbeProcessor::OnNextBatch (swiss_join.cc, 라인 2250-2416)

Probe batch 처리 핵심:

```cpp
Status JoinProbeProcessor::OnNextBatch(int64_t thread_id,
                                       const ExecBatch& keypayload_batch,
                                       arrow::util::TempVectorStack* temp_stack,
                                       std::vector<KeyColumnArray>* temp_column_arrays) {
    // ...
    int num_rows = static_cast<int>(keypayload_batch.length);

    // Mini-batch로 분할
    for (int minibatch_start = 0; minibatch_start < num_rows;) {
        uint32_t minibatch_size_next = std::min(minibatch_size, num_rows - minibatch_start);

        // 1. Hash 계산
        hash_table_->keys()->Hash(&input, hashes_buf.mutable_data(), hardware_flags);

        // 2. Hash table lookup
        hash_table_->keys()->MapReadOnly(&input, hashes_buf.mutable_data(),
                                         match_bitvector_buf.mutable_data(),
                                         key_ids_buf.mutable_data());

        // 3. Filter & Materialize
        if (join_type_ == JoinType::LEFT_SEMI || ...) {
            // Semi/Anti join: probe rows only
            RETURN_NOT_OK(materialize_[thread_id]->AppendProbeOnly(
                keypayload_batch, num_passing_ids, ...
                [&](ExecBatch batch) {
                    return output_batch_fn_(thread_id, std::move(batch));  // 즉시 출력
                }));
        } else {
            // Inner/Outer join: match pairs
            while (match_iterator.GetNextBatch(...)) {
                RETURN_NOT_OK(materialize_[thread_id]->Append(
                    keypayload_batch, num_matches_next, ...
                    [&](ExecBatch batch) {
                        return output_batch_fn_(thread_id, std::move(batch));  // 즉시 출력
                    }));
            }
        }

        minibatch_start += minibatch_size_next;
    }

    return Status::OK();
}
```

**핵심 특징**:
- Probe batch 내에서 **mini-batch로 분할** (크기: `swiss_table->minibatch_size()`)
- **각 mini-batch마다 hash lookup + filter + materialize 수행**
- **Lambda callback으로 결과를 즉시 출력** (`output_batch_fn_`)
- 함수 호출 후 즉시 반환 (streaming friendly)

---

## 3. 파이프라인 차단(Pipeline Breaker) 특성

### 3.1 Acero의 파이프라인 모델

Acero는 **pull-based execution model**을 기반으로 하되, 몇 가지 노드는 **push-based batching** 사용:

```
Source(Push)
    ↓ batch
Filter → Accumulate until condition met
    ↓ batch
HashJoin (Accumulation + Conditional Processing)
    ├─ Build side: Accumulate all batches until build complete
    └─ Probe side:
         ├ While hash_table_not_ready: Accumulate batches
         └ Once hash_table_ready: Push batches through immediately
    ↓ result batches
Sink(e.g., Aggregation)
```

### 3.2 Hash Join의 Pipeline Breaker 특성

| 구분 | 특성 | 상세 |
|------|------|------|
| **Build Side** | 완전 파이프라인 차단 | 모든 build batch를 수집할 때까지 대기 |
| **Probe Side (before hash table ready)** | 부분 파이프라인 차단 | Hash table이 준비될 때까지 probe batch 큐에 저장 |
| **Probe Side (after hash table ready)** | 거의 파이프라인 유지 | 각 probe batch 도착 시 즉시 처리, mini-batch 단위로 스트리밍 |

### 3.3 Accumulation Queue 구조

```cpp
// hash_join_node.cc 라인 1045-1047
util::AccumulationQueue build_accumulator_;  // Build batches
util::AccumulationQueue probe_accumulator_;  // Probe batches (hash table 준비 전)
util::AccumulationQueue queued_batches_to_probe_;  // Queued probe batches
```

**workflow**:
1. Probe batch 도착 → `OnProbeSideBatch()` 호출
2. Hash table 미준비 → `probe_accumulator_` 큐에 저장
3. Hash table 준비 완료 → `OnHashTableReady()` 콜백
4. Queued batches → `ProbeQueuedBatches()` 호출
5. Task group으로 batch 단위 처리 (라인 881-888):
   ```cpp
   Status ProbeQueuedBatches(size_t thread_index) {
       {
           std::lock_guard<std::mutex> guard(probe_side_mutex_);
           queued_batches_to_probe_ = std::move(probe_accumulator_);
       }
       return plan_->query_context()->StartTaskGroup(task_group_probe_,
                                                     queued_batches_to_probe_.batch_count());
   }
   ```

---

## 4. Streaming vs Pipelined 비교

### 4.1 Acero Hash Join의 특성

| 특성 | 상태 | 설명 |
|------|------|------|
| **Batch-level streaming** | ✓ Yes | Hash table 준비 후 각 probe batch를 즉시 처리 |
| **Mini-batch streaming** | ✓ Yes | `JoinProbeProcessor::OnNextBatch()` 내에서 mini-batch 단위로 처리 |
| **Incremental output** | ✓ Yes | 각 mini-batch 마다 즉시 결과 생성 (lambda callback) |
| **Pull-based pipeline** | ✗ No | Hash join은 batch를 push로 받음 |
| **Build-blocking** | ✓ Yes | Build phase 완료 전까지 probe 불가 |
| **Zero-copy buffering** | ✗ No | `probe_accumulator_` 큐에 batch 저장 필요 |

### 4.2 Streaming의 조건부 특성

```
Hash Table Ready = True    Hash Table Ready = False
     ↓                              ↓
  Streaming ✓                  Pipeline Blocked ✗
  Probe batch                  Probe batch
  → mini-batch split           → Queue
  → hash lookup                → Accumulate
  → match iterate              → Wait for table
  → materialize
  → output (lambda)
  → return immediately
```

---

## 5. Mini-batch Processing Details

### 5.1 Mini-batch 크기

```cpp
// swiss_join.cc 라인 2257
int minibatch_size = swiss_table->minibatch_size();

// 라인 2283-2284
for (int minibatch_start = 0; minibatch_start < num_rows;) {
    uint32_t minibatch_size_next = std::min(minibatch_size, num_rows - minibatch_start);
```

Default minibatch size: `arrow::util::MiniBatch::kMiniBatchLength` (보통 1024)

### 5.2 각 Mini-batch 처리 단계

1. **Hash computation** (병렬화 가능):
   ```cpp
   hash_table_->keys()->Hash(&input, hashes_buf.mutable_data(), hardware_flags);
   ```

2. **Lookup in Swiss table** (SIMD optimized):
   ```cpp
   hash_table_->keys()->MapReadOnly(&input, hashes_buf.mutable_data(),
                                    match_bitvector_buf.mutable_data(),
                                    key_ids_buf.mutable_data());
   ```

3. **Filter & aggregate results** (JoinMatchIterator 사용):
   ```cpp
   while (match_iterator.GetNextBatch(minibatch_size, &num_matches_next, ...)) {
       // Residual filter + materialize
   }
   ```

4. **Output to callback**:
   ```cpp
   return output_batch_fn_(thread_id, std::move(batch));
   ```

---

## 6. 스레드 및 병렬화

### 6.1 Probe side 병렬화

```cpp
// hash_join_node.cc 라인 984-991
task_group_probe_ = ctx->RegisterTaskGroup(
    [this](size_t thread_index, int64_t task_id) -> Status {
        return impl_->ProbeSingleBatch(thread_index,
                                       std::move(queued_batches_to_probe_[task_id]));
    },
    [this](size_t thread_index) -> Status {
        return OnQueuedBatchesProbed(thread_index);
    });
```

**특징**:
- 각 queued batch → 별도 task로 처리
- 다중 스레드에서 **병렬 처리** 가능
- 스레드 간 동기화: `thread_local` temp stacks 사용

### 6.2 Thread-local Resources

```cpp
// swiss_join.cc 라인 2524
arrow::util::TempVectorStack* temp_stack = &local_states_[thread_index].stack;
```

각 스레드가 자신의 mini-batch 처리 버퍼를 가짐 → Race condition 없음

---

## 7. 결론

### Acero Probe Side의 특성 정리

**Streaming 여부: 조건부 스트리밍 (Conditional Streaming)**

1. **Hash table 준비 전**: 파이프라인 차단 (buffering)
   - Probe batches accumulate in queue
   - Zero progress until hash table ready

2. **Hash table 준비 후**: 스트리밍 처리 (streaming)
   - Each probe batch processed immediately
   - Mini-batch level incremental processing
   - Results output via lambda callbacks
   - Multiple threads can process in parallel

### 핵심 특징

| 특성 | 상세 |
|------|------|
| **Model** | Hybrid: build-blocking push + conditional probe streaming |
| **Probe Latency** | Hash table ready까지: 높음 / 이후: 낮음 |
| **Memory** | Hash table 크기 + max queued probe batches |
| **Parallelism** | Build: sequential partitioning → parallel merge / Probe: parallel batch processing |
| **Output** | Incremental (batch/mini-batch level) |
| **Pipeline** | Build phase blocks entire pipeline / Probe phase conditionally streams |

---

## References

1. **Source Code**:
   - `/acero/_src/cpp/src/arrow/acero/hash_join_node.cc` (lines 823-888, 902-926, 984-991)
   - `/acero/_src/cpp/src/arrow/acero/swiss_join.cc` (lines 2250-2416)

2. **Key Classes**:
   - `HashJoinNode` (ExecNode implementation)
   - `SwissJoin` (HashJoinImpl implementation)
   - `JoinProbeProcessor` (Mini-batch processing)
   - `AccumulationQueue` (Batch accumulation)

3. **GitHub**: https://github.com/apache/arrow (commit-based analysis)

