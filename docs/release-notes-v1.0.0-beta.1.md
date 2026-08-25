# MacroPad Studio v1.0.0-beta.1

첫 공개 베타입니다.

## 지원 장치와 요구사항

- [지원 판매 페이지](https://www.aliexpress.com/item/1005006437127027.html)의 12키·2노브 모델
- Windows 10/11 x64, 설정 시 USB 연결, 일반 입력은 USB 또는 Bluetooth
- VID `514C`, PID `8850`, 인터페이스 `0`, Usage Page `FF00`, 25슬롯·3레이어 구조
- 한 번에 설정할 장치 한 대만 USB로 연결

## 설치

1. `MacroPadStudio-v1.0.0-beta.1-win-x64.zip`과 `.sha256`을 받습니다.
2. SHA-256을 확인하고 원하는 폴더에 압축을 풉니다.
3. `CodexKeyboardStudio.exe`를 실행합니다. 화면에는 MacroPad Studio로 표시됩니다.

## 백업과 복원

장치 변경 직전에 현재 레이어 25슬롯과 LED 상태가
`%LocalAppData%\CodexKeyboardStudio\backups\latest.json`에 저장됩니다.
문제가 생기면 앱의 `최근 백업으로 복원`을 사용하세요. 백업 체크섬이나 장치 구조가 다르면
복원 쓰기를 시작하지 않습니다.

## 포함 기능

- 지원 매크로패드의 Layer 1·2·3 키 12개와 노브 동작 6개 설정
- 키별 기본 LED와 Codex CLI 실행·승인·완료·오류 상태 표시
- PowerShell 실행 없이 앱에서 직접 처리하는 Codex 훅 설치·복구
- 변경 전 최신 로컬 백업, 적용 후 검증, 실패 시 원복, 수동 최근 백업 복원
- 한글 IME에서도 문자 단축키를 기록하고 조합 중 어떤 키를 먼저 놓아도 전체 조합 확정
- Typeless 범위는 기록한 단축키만 제공하며 설정 해제는 `선택 입력 비우기`로 처리
- Windows x64 self-contained portable 실행 패키지

## 알려진 제한

- 한 번에 지원 장치 한 대만 USB로 연결해야 합니다.
- 첫 베타는 코드 서명되지 않았습니다.
- Codex CLI 상태 연동은 사용자가 `/hooks`에서 훅을 직접 검토하고 신뢰해야 합니다.
