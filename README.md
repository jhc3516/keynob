# Keynob

**AI 도구를 손끝에서.**

A macro keypad companion for ChatGPT and Codex CLI, for Windows and macOS.

Keynob는 12키·2노브 매크로패드로 ChatGPT 앱과 Codex CLI를 활용하는 오픈 소스 앱입니다.
키와 노브에 앱별 단축키·텍스트·내장 동작을 연결하고, 선택적인 Codex CLI 상태 연동으로
작업 진행·승인 대기·완료·오류를 LED에서 확인합니다. 일반 단축키, 세 레이어와 LED 설정도 제공합니다.
macOS에서는 대상 앱에 등록된 단축키를 통해 추론 수준을 조절할 수 있습니다.
운영체제별 지원 범위와 실물 검증 결과는 아래 안내를 확인하세요.

이 프로젝트의 이전 이름은 **MacroPad Studio**입니다. 현재 소스와 이후 빌드의 이름은 Keynob이며,
기존 배포 파일과 과거 릴리스 기록은 당시 이름을 유지합니다.
`v1.0.0-beta.2`는 macOS 소스를 추가한 릴리스입니다. Windows 배포본은
[v1.0.0-beta.1](https://github.com/jhc3516/keynob/releases/tag/v1.0.0-beta.1)을 사용합니다.
[beta.2 변경 및 검증 범위](docs/release-notes-v1.0.0-beta.2.md)

![이전 MacroPad Studio Windows 화면](assets/keynob.jpg)

위 이미지는 이름 변경 전 Windows 화면입니다.

## 지원 범위

- 제품: [AliExpress 판매 페이지의 12키·2노브 모델](https://www.aliexpress.com/item/1005006437127027.html)
- 설정 연결: USB
- 일반 키 입력: USB 또는 Bluetooth
- 확인된 HID 조건: VID `514C`, PID `8850`, 인터페이스 `0`, Usage Page `FF00`, 25슬롯·3레이어 구조

| 운영체제 | 상태 | 현재 기능 |
| --- | --- | --- |
| Windows 10/11 x64 | 베타 | 키·노브·레이어·LED 설정, 백업·복원, 선택적 Codex 상태 표시 |
| macOS 13+ 빌드 대상 | 실험판 | 전역·ChatGPT·Codex CLI 키·노브·텍스트·내장 동작, LED·상태 표시, 전체 백업·복원 |

같은 VID/PID라도 보고서 구조가 다르면 지원하지 않습니다. 일치 후보가 두 대 이상 연결되면
잘못된 장치를 고르지 않도록 중단하므로 설정할 제품 한 대만 USB로 연결하세요.

## Windows에서 사용하기

1. GitHub Releases에서 `MacroPadStudio-v1.0.0-beta.1-win-x64.zip`을 받습니다.
2. 원하는 폴더에 압축을 풉니다.
3. 기존 beta.1 배포본에서는 `CodexKeyboardStudio.exe`를 실행합니다. 화면에는 이전 이름인 MacroPad Studio가 표시됩니다. 현재 소스를 빌드하면 `Keynob.exe`가 생성됩니다.
4. 레이어와 키·노브 동작을 편집한 뒤 `변경 내용 적용`을 누릅니다.

적용 직전에 현재 레이어 25슬롯과 LED 상태가
`%LocalAppData%\CodexKeyboardStudio\backups\latest.json`에 저장됩니다. 문제가 생기면 앱의
`최근 백업으로 복원`을 사용하세요. 백업 체크섬이나 장치 구조가 다르면 복원 쓰기는 시작되지 않습니다.

키보드 연결 해제, PC 절전·종료 또는 USB 오류는 기록 도중에도 발생할 수 있습니다. 중요한 기존
설정은 제조사 프로그램에서도 별도로 기록해 두는 것을 권장합니다. 이 베타는 코드 서명되지 않아
Windows가 게시자 경고를 표시할 수 있습니다.

## Windows Codex CLI 상태 연동

Codex 상태 연동은 선택 기능입니다. 앱의 `설치 / 복구`는 기존 사용자 훅을 보존하고 이 앱의 훅
7개만 직접 병합하므로 PowerShell 실행이나 실행 정책 변경이 필요 없습니다. 새 Codex CLI에서
`/hooks`를 열어 내용을 직접 검토하고 신뢰해야 동작합니다.
훅은 프롬프트나 도구 내용을 보내지 않고 이벤트 종류와 임의 세션 식별 정보만 현재 사용자용
로컬 named pipe에 전달합니다.

이 베타의 PowerShell 없는 훅 설치·복구는 자동 시험을 통과했지만, 이전 실행 정책 문제가 발생한
별도 Windows에서는 최종 빌드를 다시 검증하지 못했습니다. 설치 후 앱의 `7/7` 표시와 Codex CLI
`/hooks`를 확인하세요. 실패하더라도 키·노브·LED 설정 기능에는 영향을 주지 않습니다.

## Windows 소스 빌드

필요 항목:

- Windows x64
- .NET 10 SDK
- Visual Studio 2022 Build Tools의 C++ x86/x64 도구
- 첫 빌드 시 공식 HIDAPI 릴리스를 내려받을 인터넷 연결

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-v1-portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-v1-settings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-v1-foundation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-v1-runtime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-readiness.ps1 -DevelopmentWorktree
```

빌드 스크립트는 공식 HIDAPI 0.15.0 Windows ZIP과 x86 DLL의 SHA-256을 모두 확인합니다.
자동 시험은 실제 하드웨어 변경을 차단합니다. `-ConfirmHardwareWrite`가 필요한 실물 쓰기 진단은
일반 사용자 공개본에서 제공하지 않습니다.

## macOS 소스 빌드

macOS 포트는 Swift 6과 macOS 시스템 프레임워크만 사용합니다. Xcode 또는 현재 macOS와
버전이 맞는 Xcode Command Line Tools가 필요하며, 추가 패키지를 설치하지 않습니다.

```bash
swift run --package-path macos keynob-probe self-test
swift run --package-path macos keynob-probe discover
swift run --package-path macos Keynob
```

`.app` 번들은 `./scripts/build-macos-app.sh`로 만들 수 있습니다. macOS판은 적용 전에 세 레이어
75슬롯과 LED 전체를 자동 백업하고, 현재값 비교와 쓰기 후 재읽기 검증 및 실패 시 원복을 수행합니다.
ChatGPT·Codex CLI 범위는 macOS 손쉬운 사용 권한과 실행 중인 앱이 필요합니다. Codex CLI 범위는
앱의 전용 Terminal 실행기로 연 창에만 전달됩니다. 상세한 범위와 권한·훅 설정, CLI 명령은
[macOS 안내](macos/README.md)를 확인하세요.

Karabiner-Elements는 필수 구성요소가 아닙니다. 함께 사용한다면 입력 충돌을 피하도록
매크로패드만 Karabiner 처리 대상에서 제외하세요. 다른 키보드 설정은 유지할 수 있습니다.
[장치별 제외 방법과 입력 실패 증상](macos/README.md#karabiner-elements-사용-시)

실물 USB 점검 결과와 앱별 입력의 확인·미검증 항목은 [macOS 검증 범위](macos/README.md#검증-범위)에
정리되어 있습니다. macOS 13 실기기와 Intel USB 장치 검증은 아직 남아 있습니다.
공증된 Mac 실행 파일은 배포하지 않으며, Mac 사용자는 소스에서 로컬 앱을 빌드합니다.

## 이전 버전에서 업그레이드

앱 이름·소스 모듈·실행 파일은 Keynob로 변경했습니다. 기존 설정·백업을 그대로 읽고 훅 중복 설치를
피하기 위해 다음 호환 식별자는 유지합니다. 폴더를 수동으로 옮길 필요가 없습니다.

- Windows 데이터 폴더: `%LocalAppData%\CodexKeyboardStudio`
- macOS 데이터 폴더: `~/Library/Application Support/MacroPad Studio`
- macOS 번들 ID: `io.github.jhc3516.macropad-studio.macos`
- 설치된 macOS 훅 경로: `~/.codex/macropad-status-hook` (번들 내 파일명은 `keynob-status-hook`)
- 기존 Windows 상태 파이프·단일 실행 식별자·시작 프로그램 등록 키와 `CODEX_KEYBOARD_*` 환경변수

이전 앱과 전용 CLI 창을 종료한 뒤 Keynob를 실행하고 전용 CLI 창을 새로 여세요.
Windows 시작 프로그램을 사용했다면 Keynob에서 해당 옵션을 다시 켜 새 실행 파일 경로로 등록하세요.
macOS는 로컬 서명이 바뀌므로 손쉬운 사용 권한을 다시 등록해야 할 수 있습니다.
기존 앱은 새 Keynob가 동작하는 것을 확인한 뒤 제거할 수 있습니다.

## 라이선스

Keynob 소스는 [MIT License](LICENSE)로 제공됩니다. 이는 사용·복사·수정·배포·상업적
이용을 폭넓게 허용하지만 저작권 및 허가 고지를 유지해야 하고, 보증이나 손해배상 책임을 제공하지
않는다는 뜻입니다. self-contained 패키지에 포함된 .NET·WPF·Windows SDK 구성요소와 HIDAPI에는
별도 조건과 고지가 적용됩니다. 배포물의 `DOTNET-*`, `WPF-*`, `WINDOWS-SDK-LICENSE.rtf` 및
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
