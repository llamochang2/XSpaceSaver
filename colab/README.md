# XSpaceSaver - Colab 버전

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/llamochang2/XSpaceSaver/blob/main/colab/XSpaceSaver.ipynb)

X Space 다시듣기 음성을 `master_playlist.m3u8` URL로 받아 m4a로 저장하는 Colab 노트북.
설치 불필요 (Colab 기본 Python + ffmpeg 사용).

## 사용법

1. 위 **Open in Colab** 배지 클릭
2. 1번 셀 ▶ 실행 (준비)
3. 2번 셀에서 주의사항 5개 체크 → master URL 입력 → 저장 위치 선택 → ▶ 실행
4. PC 다운로드 또는 Google Drive `MyDrive/XSpace` 폴더에 저장됨

## 동작

1. master playlist → 첫 번째 variant playlist 로드 (`/b/` 경로 실패 시 제거 후 재시도)
2. 첫 조각 기준으로 실제 받아지는 경로 탐색
   - playlist가 가리키는 `transcode/...` 경로는 400 반환하는 경우가 있음
   - 조각 파일은 master URL과 같은 `non_transcode/...` 폴더에 존재
3. 조각 8개씩 병렬 다운로드, 실패 시 5회 재시도 후 건너뜀
4. 로컬 playlist 생성 후 ffmpeg `-c copy`로 m4a 저장 (재인코딩 없음)

## 주의

- master URL 경로에 방송 접근 키 포함. URL 입력한 상태로 노트북 저장·커밋 금지
- 다시 듣기가 켜진, 종료된 Space만 저장 가능
- 녹음 저작권은 호스트·발언자 소유. 개인 보관용으로만 사용
- X 구조 변경 시 동작하지 않을 수 있음

## 업데이트 규칙

- 코드 수정은 이 저장소의 노트북에서 먼저 진행
- 테스트는 Drive 사본에서만 실행. 실행한 노트북은 커밋하지 않음
- 커밋 전 diff에서 `master_url = "https` 포함 여부, 셀 출력(`outputs`) 비어 있는지 확인
