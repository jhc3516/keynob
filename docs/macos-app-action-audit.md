# macOS 앱별 동작 점검 결과

기준: 단축키 기록·전용 CLI 제목 판별 수정 이후 사용자가 보고한 “추론 조절 외 동작 실패” 점검.
설치된 `/Applications/ChatGPT.app`의 실제 번들 ID는 `com.openai.codex`, 버전은 `26.908.40834`였다.
이번 점검은 소스·저장 설정·설치된 앱의 명령 정의를 읽고 자동 검사를 수행했다.
대상 앱 화면 제어는 도구의 안전 제한으로 거부되어 실물 입력 성공을 확인하지 못했다.

## 확인한 문제와 수정

| 동작 | 확인한 문제 | 수정 또는 현재 처리 |
| --- | --- | --- |
| 추론 낮추기·높이기 | 등록된 사용자 단축키를 읽는 경로. 사용자 보고상 동작 | 기존 경로 유지 |
| 모델 선택기 | 저장된 앱 단축키는 Control+Command+Option+F18인데 Keynob는 Control+Shift+Option+Home 전송 | `composer.openModelPicker` 등록값 우선. 미등록 시 확인된 Control+Shift+M 사용 |
| 이전·다음 대화 | Control+PageUp/PageDown은 설치된 앱의 Mac 기본값과 다름 | `previousThread`/`nextThread` 등록값 우선, 미등록 시 Command+Shift+[ / ] 사용 |
| 대화 전환 | 고정 Control+G를 보내지만 설치된 앱의 대화 검색 명령과 연결된 근거 없음 | `searchChats` 등록값 사용. 미등록이면 안내하고 입력하지 않음 |
| 설정 | 고정 URL 사용 | `settings` 등록값 우선, 미등록 시 Command+, 사용 |
| Medium | 고정 별칭 낮추기 6회·높이기 1회. 현재 수준과 모델별 선택지를 확인하지 않음 | 임의 입력 중단, 직접 지정 미지원 안내. 저장된 기존 설정은 보존 |
| 추론 순환 | 대상 앱에 지원 명령과 사용자 등록값이 있으나 Keynob 목록에는 없었음 | `추론 수준 순환` 별도 추가. `composer.cycleReasoningEffort` 사용 |

사용자 키맵은 수정하지 않았다. 명시적 해제(null)나 잘못된 등록값을 기본값으로 우회하지 않는다.
위 키맵 연동은 `com.openai.codex` 대상이다. 별도 `com.openai.chat` 앱에서 같은 명령이 동작한다고 보장하지 않는다.

## 나머지 동작 점검

| 범위·동작 | 코드에서 확인한 전달 방식 | 판정·남은 확인 |
| --- | --- | --- |
| 양쪽 범위 일반 단축키 | 저장한 HID 키를 Mac 키 코드로 변환해 키 누름·해제 이벤트 전송 | 추론 조절도 같은 저수준 키 전송 함수 사용. q 미입력은 최신 입력 진단 필요 |
| 양쪽 범위 텍스트 | Unicode 입력을 20 UTF-16 단위 이하로 나눠 전송 | 소스상 구현 존재. 실제 입력칸 수신·한글·이모지 검증 필요 |
| Enter | Return 키 전송 | 입력칸 포커스와 대상 앱 상태 필요 |
| 복사 | Command+C | 선택 내용 필요. CLI의 마지막 응답 복사와 동일한 기능이라고 가정하지 않음 |
| 모델 메뉴 위·아래 | 방향키 전송 | 모델 메뉴가 먼저 열려 있어야 함 |
| Skills·Automations | codex URL 열기 | 설치 앱 코드에 해당 경로 처리 존재. 실제 화면 이동은 미검증 |
| CLI 추론 낮추기·높이기 | Option+, / Option+. | 공식 CLI 소스의 Alt+, / Alt+.와 일치. Terminal의 Option 전달과 현재 UI 상태는 별도 확인 |
| CLI 세션 재개 | /resume 텍스트 + Enter | 입력칸이 비어 있는지와 실제 명령 실행 확인 필요 |
| CLI 문제 진단·프로젝트 설명·문서 점검 | 각 요청 문장 + Enter | 실제 전송 시험은 수행하지 않음. 테스트 프로젝트에서 확인 필요 |

현재 저장 설정에서 확인한 앱별 동작은 KEY 1의 CLI q, KNOB 1의 추론 낮추기·높이기·Medium,
KNOB 2 누르기의 모델 선택기였다. 다른 동작이 실제로 시험됐는지는 이 설정만으로 알 수 없다.
“나머지 전부 실패”가 한 가지 원인 때문이라고 확정하지 않는다.

## 검증

- 자동 self-test: 214개 통과. 새 명령 매핑, 사용자 등록값 우선, Mac 기본값, 명시적 해제·잘못된 등록값 거부 포함.
- 훅 통신 검사: 통과.
- XCTest: 현재 도구 체인에 모듈이 없어 생략.
- 실제 키·노브 및 대상 앱 반응: 미검증. 자동 검사 통과를 실물 성공으로 간주하지 않음.

## 다음 실물 확인

1. 새 Keynob 실행 후 새로 고침·라우터 시작. 권한 판정 실패 시 새 앱 재등록.
2. KNOB 2 누르기 모델 선택기가 열리는지 확인.
3. Medium을 원한다면 모델 선택기에서 직접 선택. 순환 시험은 동작을 `추론 수준 순환`으로 명시적으로 바꾼 후 적용.
4. 새 전용 CLI 창의 빈 입력칸에서 KEY 1의 q를 한 번 시험하고 입력 전달 진단을 기록.
5. 같은 범위에서 단축키 q와 텍스트 q를 각각 적용해 입력 차이를 비교. 시험 후 원래 설정으로 복구.

## 근거

- [앱 입력 전달 구현](../macos/Sources/Keynob/AppRouting.swift)
- [대상 앱 단축키 해석](../macos/Sources/KeynobCore/CodexAppKeybindings.swift)
- [내장 동작 목록](../macos/Sources/KeynobCore/Routing.swift)
- 설치된 앱 `Contents/Resources/app.asar`의 `.vite/build/src-CCXHtyvY.js` 명령 정의 및 `main-DaMR-wdT.js` 경로 처리
- [공식 CLI 추론 단축키 구현](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/reasoning_shortcuts.rs)
