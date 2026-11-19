# space_dl

X Space 다시듣기 음성을 `master_playlist.m3u8` URL로 받아 m4a로 저장하는 스크립트.

플레이리스트에 적힌 조각 경로(`transcode/...`)가 실제 위치(`non_transcode/...`)와 달라 400이 나는 문제를 자동 보정함.

## 요구 사항

- Python 3.9 이상 (표준 라이브러리만 사용)
- ffmpeg (PATH에 등록)

```powershell
winget install --id Python.Python.3.12 -e
winget install --id Gyan.FFmpeg -e
```

## 사용법

```powershell
python space_dl.py "<master_playlist.m3u8 URL>"
python space_dl.py "<URL>" -o 파일명.m4a
python space_dl.py            # 실행 후 URL 입력
```

| 옵션 | 설명 |
|---|---|
| `-o`, `--output` | 저장 파일명. 기본값 `space_날짜_시간.m4a` |
| `--workers` | 동시 다운로드 수. 기본 8 |
| `--keep` | 임시 조각 폴더 유지 |

## 동작

1. master playlist에서 variant playlist 로드 (`/b/` 경로 실패 시 제거 후 재시도)
2. 첫 조각 기준으로 받아지는 경로 탐색 (playlist 폴더 → master 폴더 순)
3. 조각 병렬 다운로드, 실패 조각은 5회 재시도 후 건너뜀
4. 로컬 playlist 생성 후 ffmpeg로 재인코딩 없이 m4a 저장

## 주의

- master URL 경로에 방송 식별 키가 포함됨. 공개 저장소·게시판에 올리지 말 것.
- 호스트가 녹음을 삭제하거나 비공개로 바꾸면 받을 수 없음.
- 진행 중인 Space는 지원하지 않음 (다시듣기 전용).
