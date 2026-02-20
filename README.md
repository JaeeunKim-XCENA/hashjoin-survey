# Hash Join Survey

## Docker

### 빌드

```bash
docker build -t hashjoin-survey .
```

### 실행

```bash
docker run -it \
    -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
    -v $(pwd):/home/jekim/workspace \
    -v ~/.claude:/home/jekim/.claude \
    hashjoin-survey
```

- 컨테이너는 `jekim` 유저로 실행된다 (sudo 권한 있음)
- `-v $(pwd):/home/jekim/workspace` — 작업 디렉토리 마운트. 분석 결과가 호스트에도 반영된다.
- `-v ~/.claude:/home/jekim/.claude` — 호스트의 Claude 설정/메모리를 컨테이너와 공유한다.

### 실행 중인 컨테이너에 접속

```bash
# 컨테이너 ID 또는 이름 확인
docker ps

# bash 셸로 접속
docker exec -it <container_id> bash
```

`--rm` 옵션 없이 실행한 경우, 컨테이너가 중지된 상태라면 먼저 시작한 뒤 접속한다:

```bash
docker start <container_id>
docker exec -it <container_id> bash
```

### 컨테이너 내 사용 가능 도구

| 도구 | 용도 |
|------|------|
| `claude` | Claude Code CLI |
| `tmux` | 터미널 멀티플렉서 |
| `agent-deck` | AI 에이전트 세션 관리 |
| `git` | 소스 코드 클론/관리 |
| `rg` | ripgrep 코드 검색 |
| `g++` / `cmake` | C++ 빌드 |
| `python3` | 스크립트 실행 |
| `curl` / `wget` | 웹 요청 |
| `sudo` | 루트 권한 필요 시 |
