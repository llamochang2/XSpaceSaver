# XSpaceSaver

X Space 다시듣기 음성을 `master_playlist.m3u8` URL로 받아 m4a로 저장하는 도구.

X가 내려주는 playlist의 조각 경로(`transcode/...`)가 실제 파일 위치(`non_transcode/...`)와 달라 ffmpeg·yt-dlp에서 조각마다 HTTP 400이 나는 문제를 자동 보정함.

## 버전

| 폴더 | 대상 | 필요한 것 | 비고 |
|---|---|---|---|
| [`colab/`](colab/) | 누구나 (권장) | Google 계정 | 설치 불필요. [![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/llamochang2/XSpaseSaver/blob/main/colab/XSpaceSaver.ipynb) |
| [`windows/`](windows/) | Windows 사용자 | ffmpeg (버튼으로 설치) | PowerShell GUI. `XSpaceSaver.bat` 더블클릭 |
| [`python/`](python/) | 개발자 | Python 3.9+, ffmpeg | CLI. 표준 라이브러리만 사용 |

## 동작

1. master playlist → variant playlist 로드
2. 첫 조각 기준으로 실제 응답하는 경로 탐색 (playlist 폴더 → master 폴더)
3. 조각 병렬 다운로드 (실패 시 재시도 후 건너뜀)
4. ffmpeg `-c copy`로 m4a 저장 (재인코딩 없음)

## 주의

- 다시 듣기가 켜진, 종료된 Space만 저장 가능
- 녹음 저작권은 호스트·발언자 소유. 개인 보관용으로만 사용
- master URL 경로에 방송 접근 키 포함. 이슈·PR·커밋에 URL 포함 금지
- X 구조 변경 시 동작하지 않을 수 있음

## 상태

- `python/`: 가짜 서버(경로 불일치 재현) 테스트 통과
- `colab/`: 셀 로직 테스트 통과, 실제 Colab 환경 미검증
- `windows/`: 실제 Windows 환경 미검증
