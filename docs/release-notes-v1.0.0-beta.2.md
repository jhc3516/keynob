# MacroPad Studio v1.0.0-beta.2

macOS 네이티브 소스를 추가한 실험판입니다. 기존 Windows 소스·실행 파일은 변경하지 않습니다.

## 운영체제별 사용

- Windows: [v1.0.0-beta.1의 win-x64 ZIP](https://github.com/jhc3516/macropad-studio/releases/tag/v1.0.0-beta.1)을 계속 사용하세요.
- Mac: 이 태그의 소스를 받아 `./scripts/build-macos-app.sh`로 로컬 Universal 앱을 빌드하세요.
  실행 파일은 `artifacts/macos/MacroPad Studio.app`에 생성됩니다. Swift 6 이상과 호환되는
  Xcode/Command Line Tools가 필요하며 추가 패키지는 설치하지 않습니다.
- 공증된 Mac 실행 파일은 이번 릴리스에 포함하지 않습니다. 번들 버전은 `1.0.0` / build `3`이며
  이 Git 태그와 함께 실험판으로 구분합니다.

## 추가 기능

- SwiftUI 설정 앱, JSON CLI, IOKit USB 통신
- 4×3 키 배열과 Knob 1·2 위치 선택, 시계 방향·반시계 방향·누르기 표기
- 세 레이어의 키·노브 설정, LED 모드와 12개 개별 색상
- 전역 단축키, ChatGPT·전용 Codex CLI 범위의 단축키·텍스트·내장 동작
- 전체 75슬롯·LED 자동 백업, 적용 검증·실패 시 원복, 명시적 확인 후 백업 복원
- 선택적 Codex CLI 훅·상태 LED, 기존 훅 보존 및 프롬프트 본문 미전달
- Apple Silicon·Intel GitHub Actions 시험과 Universal 앱 빌드

Typeless는 제외합니다. 앱 전용 범위에서는 macOS가 전달할 수 없는 PC 전용 키를 제한하며,
장치 직접 입력 목록은 유지합니다. Windows와 Mac에서 같은 단축키의 의미가 다를 수 있습니다.

## 공개 전 보완

- 지원되지 않는 앱 전용 키와 잘못된 보조키를 적용 전에 거부합니다.
- 앱 전용 별칭이 비대상 앱이나 키 반복 이벤트로 새지 않도록 처리합니다.
- 화면을 읽은 뒤 바뀐 슬롯·LED를 감지해 적용을 중단합니다.
- 상태 LED 작업을 취소·완료 대기한 뒤 수동 설정을 처리하고, 앱이 표시한 상태 색상만 복원합니다.
- 한 설정 창을 사용하며, 상태 소켓의 비동기 종료·읽기 시간 제한과 훅 오류 표시를 보완합니다.

## 확인한 범위와 남은 확인

- macOS 26.5.1 Apple Silicon: 지원 USB 장치 인식, 별칭 슬롯 임시 변경·복원, LED 임시 변경·복원.
- 실물 진단 전후: 75슬롯과 LED 전체 상태가 동일함을 확인.
- 로컬 자동 회귀 시험 57개, 훅 전달·본문 비공개 시험, Apple Silicon·Intel Universal 빌드 및 서명 구조 검사.
- 로컬 Command Line Tools에는 XCTest가 없어 해당 단위 테스트는 생략됩니다. GitHub Actions에서는
  전체 Xcode와 `MACROPAD_REQUIRE_XCTEST=1`을 사용합니다. 실행 결과는
  [macOS Actions](https://github.com/jhc3516/macropad-studio/actions/workflows/macos.yml)에서 확인하세요.

화면 잠금으로 실제 앱 클릭, 권한 허용 후 키 전달, 전용 Terminal 및 Codex 상태 LED의 최종 수동
시험은 완료하지 못했습니다. macOS 13 실기기와 Intel USB 장치도 아직 확인하지 않았습니다.
따라서 이번 버전은 **Mac 소스 실험판**이며 모든 Mac에서 문제없이 작동한다는 보증은 아닙니다.

권한, 백업·복원 및 수동 점검 방법: [macOS README](https://github.com/jhc3516/macropad-studio/blob/v1.0.0-beta.2/macos/README.md)
