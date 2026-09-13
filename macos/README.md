# MacroPad Studio for macOS

기존 Windows 구현과 나란히 유지되는 네이티브 Swift/SwiftUI 포트입니다. 지원 장치를 정확히
식별하고 세 레이어의 키·노브, 앱별 동작과 12개 LED를 읽고 설정합니다.

## 지원 범위

- 빌드 대상: macOS 13 이상, Apple Silicon 및 Intel (실험판)
- USB로 연결된 VID `514C`, PID `8850`, Usage Page `FF00`, 인터페이스 `0` 장치 한 대
- Layer 1~3의 KEY 1~12와 두 노브의 CCW(반시계 방향)·Press·CW(시계 방향), 레이어당 18개 입력
- 앱의 4×3 키 배열과 Knob 1·2 패널에서 설정할 입력을 위치로 선택
- Command·Control·Option·Shift 최대 4개와 일반 HID 키 하나, 보조키만, 또는 입력 비활성화
- 모든 프로그램, ChatGPT 전용, Codex CLI 전용 범위
- ChatGPT·Codex CLI 범위의 단축키, 최대 2,000자 텍스트와 범위별 내장 동작
- 앱이 연 전용 Terminal 창과 Codex CLI 상태 훅·상태 LED
- LED mode 0~5와 KEY 1~12의 개별 색상
- 전체 장치 백업, 체크섬 검증, 최근 백업 복원
- SwiftUI 앱과 자동화용 JSON CLI

Windows판의 Typeless 범위와 Typeless 동작은 macOS판에서 지원하지 않습니다. 앱 전용 범위의
일반 키 목록은 macOS가 전달할 수 있는 키로 제한됩니다. F21~F24, PrintScreen 등 일부 PC 전용
키는 앱 전용 목록에 없지만 장치 직접 입력 목록에는 유지됩니다. 모든 프로그램
범위는 장치가 직접 실행합니다. ChatGPT·Codex CLI 범위는 장치에 고유 별칭을 기록하고 실행 중인
MacroPad Studio가 이를 가로채 정확한 전경 앱을 다시 확인한 뒤 동작을 전달합니다.
라우터가 실행 중이면 비대상 앱에서는 설정된 별칭을 소비하고 동작을 전달하지 않습니다.

## 앱별 동작과 권한

1. 앱에서 장치를 새로 고친 뒤 키 또는 노브의 범위를 `ChatGPT에서만` 또는
   `Codex CLI에서만`으로 정하고 동작을 적용합니다.
2. `앱 · Codex` 탭에서 `권한 확인 후 시작`을 누릅니다.
3. macOS의 `개인정보 보호 및 보안 › 손쉬운 사용`에서 MacroPad Studio를 허용하고 라우터를
   다시 시작합니다.
4. Codex CLI 범위는 같은 탭의 전용 실행기로 작업 폴더를 골라 연 Terminal 창에서만 동작합니다.
   Terminal 제어를 처음 사용할 때 macOS 자동화 권한 확인이 나타날 수 있습니다.

앱별 동작은 MacroPad Studio가 실행 중이어야 합니다. 앱이 꺼져 있거나 권한이 없으면 장치가 보내는
별칭 조합이 그대로 전달될 수 있으므로, 앱별 범위를 사용할 때 앱을 먼저 실행하세요. 텍스트 동작은
`~/Library/Application Support/MacroPad Studio/settings.json`에 권한 `0600`의 평문으로
저장되므로 암호·토큰 같은 비밀은 넣지 마세요.

### ChatGPT/Codex 추론 수준 단축키

`추론 수준 낮추기`와 `추론 수준 높이기`는 대상 데스크톱 앱의 `composer.decreaseReasoningEffort`와 `composer.increaseReasoningEffort`에 등록된 단축키를 읽어 전달합니다. 대상 앱의 **설정 › 키보드 단축키**에서 두 동작을 먼저 등록하세요. [공식 단축키 설정 안내](https://learn.chatgpt.com/docs/reference/commands#keyboard-shortcuts)

이 연동은 `com.openai.codex` 데스크톱 앱과 `~/.codex/keybindings.json`을 사용합니다. MacroPad Studio에 `CODEX_HOME` 환경 변수가 있으면 그 디렉터리의 파일을 읽으므로, 대상 앱과 같은 디렉터리를 사용해야 합니다. 키맵은 입력마다 다시 읽으며 생성하거나 수정하지 않습니다. 단축키가 없거나 해제되어 있거나 지원하지 않는 키 조합이면 입력을 보내지 않고 `앱 · Codex` 탭에 이유를 표시합니다.

매크로패드에 저장하는 `Control+Shift+Option` 별칭과 대상 앱의 동작 단축키는 서로 다른 설정입니다. 별칭은 MacroPad Studio가 입력을 구별하는 용도이며, 대상 앱이 그 조합을 추론 수준 명령으로 알아듣는다는 뜻은 아닙니다. 이 연동 수정은 낮추기·높이기에 한정됩니다. `추론 수준 Medium`과 다른 내장 동작의 실물 호환성은 별도로 검증해야 합니다.

## Karabiner-Elements 사용 시

Karabiner-Elements는 MacroPad Studio의 필수 구성요소가 아닙니다. 설치되어 있다면 매크로패드만
Karabiner 입력 처리에서 제외하는 것을 권장합니다. 손쉬운 사용 권한이 허용되고 라우터가 실행 중이어도,
Karabiner가 장치 입력을 함께 처리하면 앱별 동작이 실행되지 않을 수 있습니다.

1. Karabiner-Elements의 `Devices` 탭을 엽니다.
2. 매크로패드의 **VID `20812` (`0x514C`), PID `34896` (`0x8850`)**를 확인합니다.
   장치 이름은 `USB Composite Device`로 표시될 수 있으므로 이름만으로 선택하지 마세요.
3. 해당 장치의 `Modify events`만 끕니다. 다른 키보드의 설정은 변경하지 않으며,
   Karabiner 전체를 종료하거나 삭제할 필요도 없습니다.
4. MacroPad Studio에서 `새로 고침` 후 입력 라우터를 시작하고, 대상 앱의 빈 입력칸에서 실물 키를
   다시 테스트합니다. 이미 라우터가 실행 중이면 그대로 테스트할 수 있습니다.

이 설정은 현재 Karabiner 프로필에 저장됩니다. 프로필을 바꾸면 매크로패드의 제외 상태도 다시
확인하세요. 장치에 저장한 키·LED 설정은 바뀌지 않지만, 해당 매크로패드에 적용하던 Karabiner 변환은
사용하지 않게 됩니다. [Karabiner 공식 장치 선택 안내](https://karabiner-elements.pqrs.org/docs/manual/configuration/configure-devices/)

Layer 1의 KEY 1은 앱별 라우팅에 `Control+Shift+Option+F1` 별칭을 사용합니다. Karabiner와 macOS의
기능 키 설정에 따라 F1~F12가 밝기·음량 같은 미디어 키로 처리될 수 있습니다.
[Karabiner 공식 기능 키 설명](https://karabiner-elements.pqrs.org/docs/help/how-to/function-keys/)
이는 입력 실패의 가능한 경로이며, 아래 실물 시험에서 실제로 어떤 키로 변환됐는지까지 확인한 것은 아닙니다.

## Codex 상태 LED

`앱 · Codex` 탭의 `설치 / 복구`는 사용자가 눌렀을 때만 기존 `~/.codex/hooks.json`을 백업하고
기존 훅을 보존한 채 이 앱의 7개 상태 훅을 병합합니다. 설치 후 전용 Codex CLI에서 `/hooks`를 열어
내용을 직접 검토하고 신뢰해야 합니다. 훅 클라이언트는 프롬프트와 도구 내용을 버리고 이벤트 종류,
세션·턴 식별자와 전용 실행기 식별자만 현재 사용자용 Unix 소켓에 전달합니다. 일반 Terminal에서
실행한 Codex 세션은 상태 LED 대상이 아닙니다.

상태 색은 실행 중 파랑, 승인 대기 노랑, 완료 초록, 오류 빨강입니다. 완료 색을 잠시 표시한 뒤 앱에
설정한 기본 LED 배치로 복원합니다. 훅 설치·제거 실패는 키·노브·기본 LED 설정에 영향을 주지 않습니다.
상태 표시 중 다른 프로그램이 LED를 바꾸면 그 값을 덮어쓰지 않습니다. 이전 개발판의 상태 파일에
표시했던 색상 정보가 없으면 자동 복원을 생략하므로, 필요한 기본 색상을 LED 탭에서 다시 적용하세요.

## 쓰기 안전장치

키·노브 또는 LED를 적용하기 전에 앱은 다음 내용을 기본적으로
`~/Library/Application Support/MacroPad Studio/backups/latest.json`에 원자적으로 저장합니다.

- 장치 VID/PID/Usage Page/인터페이스와 보고된 일련번호
- 세 레이어의 75개 원시 슬롯 보고서
- LED 모드와 12개 RGB 값
- 백업 전체의 SHA-256 체크섬

앱에서 적용할 때는 해당 슬롯 또는 LED가 화면을 읽었을 때의 값과 같은지 먼저 확인하며,
다르면 새로 고침을 요구하고 쓰지 않습니다. 각 슬롯 쓰기는 트랜잭션 직전 값도 다시 비교한 뒤 슬롯 쓰기와 커밋을
수행합니다. 전체 레이어를 다시 읽어 목표 바이트와 정확히 같은지 확인하며, 실패하면 원본을
강제로 다시 기록하고 원복도 재검증합니다. LED도 세 보고서를 전송한 후 같은 방식으로 확인하고
실패 시 원복합니다. 최근 백업 복원은 앱이 관리하는 3개 레이어의 54개 키·노브 입력과 LED 상태를
대상으로 하며, 나머지 예약 슬롯은 안전을 위해 기록하지 않습니다. 예약 슬롯이 백업과 달라졌다면
복원 자체를 거부하고, 완료 판정 전에는 75개 슬롯과 LED 전체가 백업과 같은지 확인합니다. 복원
전에는 현재 상태를 별도의 `pre-restore-*.json`으로 저장합니다. 이 제품군은 서로 다른 두 실물도
같은 시리얼을 보고한 사례가 있어, 시리얼은 진단값으로만 비교하고 사용자가 현재 연결된 한 대에
복원할지 명시적으로 확인해야 합니다.

USB 분리나 전원 손실은 어떤 소프트웨어도 완전히 막을 수 없습니다. 중요한 설정은 백업 파일과
제조사 프로그램에도 별도로 기록해 두는 것을 권장합니다.

## 빌드와 실행

Xcode 또는 현재 macOS와 버전이 맞는 Xcode Command Line Tools, Swift 6 이상이 필요합니다.
추가 패키지나 Homebrew 설치는 필요하지 않습니다.

```bash
swift run --package-path macos MacroPadStudioMac
./scripts/build-macos-app.sh
open "artifacts/macos/MacroPad Studio.app"
```

만들어진 앱은 로컬 ad-hoc 서명만 적용됩니다. 다른 Mac에 배포하려면 Developer ID 서명과
Apple 공증 절차가 별도로 필요합니다.

앱을 다시 빌드해 교체하면 실행 파일의 서명이 달라져 기존 손쉬운 사용 허용이 맞지 않을 수 있습니다. 목록에서 켜져 있는데도 새 앱의 권한 검사가 실패한다면 MacroPad Studio를 종료하고, 아래 명령으로 **이 앱의 이전 허용만 초기화**한 뒤 현재 `.app`을 손쉬운 사용 목록에 다시 추가하고 허용하세요. 이 명령은 다른 앱의 권한을 초기화하지 않으며, 재등록에는 사용자의 macOS 인증이 필요할 수 있습니다.

```bash
/usr/bin/tccutil reset Accessibility io.github.jhc3516.macropad-studio.macos
```

재등록 후 MacroPad Studio에서 `새로 고침`과 `권한 확인 후 시작`을 실행합니다. 앱 빌드나 실행 과정에서 권한을 자동 초기화하지는 않습니다.

## CLI와 테스트

읽기와 무변경 시험:

```bash
swift run --package-path macos macropad-probe self-test
swift run --package-path macos macropad-probe discover
swift run --package-path macos macropad-probe read-layer 1
swift run --package-path macos macropad-probe read-led
swift run --package-path macos macropad-probe read-app-shortcuts
swift run --package-path macos macropad-probe backup
./scripts/test-macos.sh
```

실물 쓰기 진단 명령은 먼저 전체 백업을 저장하고, 임시값을 적용·재검증한 뒤 즉시 원래 값으로
되돌립니다. 장치가 안정적으로 연결된 상태에서만 사용하세요.

```bash
swift run --package-path macos macropad-probe diagnostic-slot-rollback 3 1
swift run --package-path macos macropad-probe diagnostic-routing-alias-rollback 3 1
swift run --package-path macos macropad-probe diagnostic-led-rollback
```

CLI 복원은 동일한 이유로 `--confirm-family-device` 플래그를 반드시 요구합니다. 저수준
`program-slot`, `program-led`, `restore-backup` 명령의 전체 인자는 `macropad-probe help`로
확인할 수 있습니다. 모든 쓰기 명령도 실행 직전에 전체 백업을 만듭니다.

`self-test`는 하드웨어를 변경하지 않고 요청 바이트, 장치 선택, 보고서 검증, 단축키 왕복,
54개 라우팅 별칭의 유일성, 범위 규칙, 설정 왕복, LED 팔레트와 백업 오염 감지를 검사합니다.
`read-app-shortcuts`는 실제 사용자 키맵에서 추론 수준 낮추기·높이기 단축키를 읽기만 하며, 키 입력을 보내지 않습니다. 자체 검사에는 키맵 해석, 미등록·해제·잘못된 형식의 입력 차단, 파일 변경 반영 및 원본 보존 검사도 포함됩니다.
`scripts/test-macos-hook.sh`는 임시 Unix 소켓에서 훅 이벤트 전달과 프롬프트 본문 미전달을 검사합니다.
로컬 Swift 컴파일러와 SDK 버전이 맞지 않으면 `swift test` 자체가 시작되지 않을 수 있으므로
Xcode/Command Line Tools 버전을 맞춰야 합니다.
Command Line Tools에 XCTest 모듈이 없을 때만 단위 테스트 생략을 명시합니다. 전체 Xcode가
있는 환경에서는 `MACROPAD_REQUIRE_XCTEST=1 ./scripts/test-macos.sh`로 생략을 금지할 수 있습니다.
GitHub Actions는 Apple Silicon·Intel 러너에서 이 전체 시험과 Universal 앱 빌드를 수행합니다.

## 검증 범위

beta.2의 USB 검증은 macOS 26.5.1 Apple Silicon에서 수행했습니다. USB 인식과 라우팅 별칭 슬롯·LED의
임시 기록·원복을 실물로 점검했고, 전후 75슬롯과 LED 전체 상태가 동일함을 확인했습니다. 자동 시험과 Universal
빌드는 실물의 모든 키·노브 조작이나 다른 OS 버전에서의 실행을 대신하지 않습니다.

2026-09-13에는 macOS 26.6.2 Apple Silicon과 Karabiner-Elements 16.3.0 환경에서
`Layer 1 / KEY 1 / ChatGPT에서만 / 텍스트 입력 /model`을 추가로 확인했습니다. 손쉬운 사용·입력 전송
권한 검사와 라우터 활성 상태가 정상인데도 입력되지 않았으나, 매크로패드의 `Modify events`만 끈 뒤
설치된 대상 앱의 입력칸에 `/model`이 입력되는 것을 사용자가 실물 키로 확인했습니다.

같은 환경의 ChatGPT/Codex 데스크톱 앱 `26.903.71938`에서는 `Layer 1 / KNOB 1 / ChatGPT에서만`의 CCW(반시계 방향) `추론 수준 낮추기`와 CW(시계 방향) `추론 수준 높이기`도 사용자가 실물로 확인했습니다. 고정 단축키 대신 대상 앱의 등록된 단축키를 읽도록 수정한 앱으로 교체하고, 새 실행 파일의 손쉬운 사용 권한을 다시 등록한 뒤 양방향 동작을 확인했습니다. 대상 앱의 단축키 파일, MacroPad의 키 설정과 Karabiner 제외 설정은 변경하지 않았습니다.

이 실물 결과는 한 장치의 KEY 1 텍스트 입력과 KNOB 1 양방향 추론 수준 조절에 한정됩니다. KNOB 1 누르기의 `Medium`, KNOB 2, 다른 레이어, 비대상 앱에서의 차단과 전용 CLI 동작까지 통과했다는 뜻은 아닙니다.

전체 수동 점검은 다음 순서로 수행하세요.

1. 앱에서 4×3 키와 Knob 1·2를 선택하고 시계 방향·반시계 방향·누르기 구분을 확인합니다.
2. 백업을 만든 뒤 전역 단축키를 적용하고 실제 키·노브 입력, LED 적용 및 백업 복원을 확인합니다.
3. 손쉬운 사용·자동화 권한을 허용한 뒤 ChatGPT 전용 입력이 대상 앱에서만 동작하는지 확인합니다.
4. 전용 실행기로 연 Codex CLI 창과 일반 Terminal 창을 번갈아 선택하여 입력 범위를 확인합니다.
5. 선택적으로 훅을 설치하고 Codex CLI에서 신뢰한 뒤 실행·승인·완료·오류 LED를 확인합니다.

위 1~5의 전체 흐름은 아직 최종 검증을 완료하지 않았습니다. macOS 13 실기기와 Intel USB 장치
검증도 남아 있으므로 안정판 호환성을 보증하지 않습니다.

## 구조

- `Sources/CHIDBridge`: IOKit 기반 정확 장치 선택 및 트랜잭션 쓰기·검증·원복
- `Sources/MacroPadCore`: 프로토콜, 단축키 코덱, 백업과 구성 서비스
- `Sources/MacroPadProbe`: 읽기, 백업, 복원과 실물 진단 JSON CLI
- `Sources/MacroPadStatusHook`: 내용 최소화 Codex 훅 클라이언트
- `Sources/MacroPadStudioMac`: SwiftUI 설정 앱, 입력 라우터, 전용 실행기와 상태 수신기
- `Tests/MacroPadCoreTests`: 하드웨어가 필요 없는 프로토콜·백업 단위 테스트
