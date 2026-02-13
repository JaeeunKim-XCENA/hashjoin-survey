# Hash Join Survey

## Project Goal
Modern OLAP engine들의 Hash Join 구현을 분석하고 정리하는 서베이 프로젝트.

## Target Engines
- **DuckDB** — C++, vectorized push-based
- **Velox** (Meta) — C++, vectorized
- **ClickHouse** — C++, column-oriented
- **Apache DataFusion** — Rust, Arrow-based
- **Apache Arrow Acero** — C++, Arrow-native execution engine
- **RAPIDS cuDF** — CUDA/C++, GPU hash join (GPU 특성과 알고리즘 연결 필수)
- **Polars** — Rust, Arrow-based
- **Umbra / HyPer** — 학술 기반 엔진 (논문 중심)

## Directory Structure
```
hashjoin-survey/
├── CLAUDE.md
├── duckdb/
├── velox/
├── clickhouse/
├── datafusion/
├── acero/
├── rapids-cudf/
├── polars/
└── umbra-hyper/
```
각 엔진 디렉토리에 해당 엔진의 분석 결과를 정리한다.

## Analysis Methodology (우선순위 순)
1. **소스 코드 분석** — 최우선. GitHub 저장소의 실제 코드를 기반으로 분석.
2. **논문/아티클** — 코드와 함께 보조 자료로 활용. 반드시 **출처(제목, 저자, 날짜, URL)**를 명시.
3. **공식 문서/블로그** — 추가 컨텍스트 제공 시 활용.

## Per-Engine Analysis Template
각 엔진의 분석은 다음 항목을 포함해야 한다:
- **Hash Table 구조**: 어떤 hash table을 사용하는가 (open addressing, chaining, Swiss table 등)
- **Build Phase**: 빌드 측 데이터를 어떻게 hash table에 적재하는가
- **Probe Phase**: 프로브 측에서 어떻게 매칭하는가
- **Partitioning 전략**: radix partitioning, grace hash join 등
- **Parallelism**: 병렬 빌드/프로브 방식 (thread-level, partition-level)
- **Memory Management**: spill-to-disk, 메모리 제한 처리
- **Join Types 지원**: inner, left, right, full outer, semi, anti, mark 등
- **Key References**: 소스 코드 경로, 논문, 블로그 포스트 (출처+날짜 필수)

## GPU (RAPIDS cuDF) 추가 분석 항목
- GPU thread/block/warp 단위 병렬 처리와 join 알고리즘의 매핑
- Shared memory / global memory 활용 전략
- CPU hash join과의 구조적 차이점

## Work Conventions
- 최대한 **병렬**로 에이전트를 띄워서 진행한다.
- 각 엔진은 독립 작업 단위이므로 동시에 분석 가능하다.
- 출처 없는 정보는 기재하지 않는다.
- 코드 인용 시 파일 경로와 함수명을 명시한다.
- 언어: 한국어 기본, 코드/기술 용어는 영문 그대로 사용.
