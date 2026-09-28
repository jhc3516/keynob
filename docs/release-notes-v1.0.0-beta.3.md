# Keynob v1.0.0-beta.3

Keynob 이름으로 제공하는 Windows 베타 실행 파일과 Windows·macOS 소스입니다.

## 다운로드와 실행

1. `Keynob-v1.0.0-beta.3-win-x64.zip`과 해당 `.sha256` 파일을 받습니다.
2. SHA-256을 확인하고 새 폴더에 압축을 모두 풉니다.
3. 이전 앱과 전용 Codex CLI 창을 종료하고 `Keynob.exe`를 실행합니다.

Windows 10/11 x64용 self-contained 패키지이며 별도 .NET 설치가 필요 없습니다.
소스는 `Keynob-v1.0.0-beta.3-source.zip`과 해당 `.sha256`으로 제공합니다.
macOS는 소스를 받아 `./scripts/build-macos-app.sh`로 `Keynob.app`을 빌드하세요.
이번 릴리스에는 공증된 Mac 실행 파일을 포함하지 않습니다.

## 변경 내용

- 공개 앱 이름, 실행 파일, 소스 모듈, 아이콘 및 배포 ZIP 이름을 Keynob로 통일했습니다.
- README와 Windows 설치 안내가 Keynob 배포본을 가리킵니다.
- Windows 전용 Codex CLI 실행기는 `--no-daemon`을 명시해 Codex CLI 0.158.0의 시작 경고를 제거합니다.
- 기존 단축키·레이어·LED 설정, 백업·복원, 선택적 Codex 상태 훅 기능을 유지합니다.

## 기존 사용자

기존 설정·백업과 훅을 계속 사용하도록 데이터 폴더와 호환 식별자는 유지합니다.
폴더를 수동으로 이름 변경할 필요가 없습니다. 시작 프로그램과 macOS 권한을 포함한
이전 절차는 [업그레이드 안내](https://github.com/jhc3516/keynob/blob/v1.0.0-beta.3/docs/upgrading.md)를 확인하세요.
beta.1·beta.2 자료는 당시 배포 내용을 설명하는 이력으로 보존합니다.

## 알려진 제한

- Windows 실행 파일은 코드 서명되지 않았습니다.
- 설정 시 지원하는 12키·2노브 장치 한 대만 USB로 연결하세요.
- Codex 상태 훅은 새 CLI의 `/hooks`에서 직접 검토하고 신뢰해야 합니다.
- Windows 실행기의 `--no-daemon`은 Codex CLI 0.158.0에서 검증했습니다. 구버전 호환성은 미검증입니다.
- 별도 Windows PC의 훅 설치와 실물 키·LED 동작을 이번 배포 과정에서 다시 검증하지 않습니다.
- macOS는 소스 실험판입니다. 지원 범위와 수동 확인 항목은
  [macOS 안내](https://github.com/jhc3516/keynob/blob/v1.0.0-beta.3/macos/README.md)를 확인하세요.
