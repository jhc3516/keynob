# 문서 목록

[프로젝트 소개](../README.md)

## 사용 및 점검

| 문서 | 내용 |
| --- | --- |
| [Windows 안내](windows.md) | 설치, 상태 훅, 소스 빌드와 검증 |
| [macOS 안내](../macos/README.md) | 지원 범위, 빌드, 단축키 기록, 권한과 입력 문제 해결 |
| [macOS 앱별 동작 점검 기록](macos-app-action-audit.md) | 특정 앱 버전 기준의 수정 근거와 미검증 항목. 전체 동작 보증이 아닌 개발 기록 |

## 버전과 기존 설치

릴리스 태그와 플랫폼별 앱 버전은 별개입니다. `main`에는 태그 이후의 개발 변경이 포함될 수 있습니다.

| 구분 | 기준 |
| --- | --- |
| Windows 소스 버전 | [`Keynob.csproj`](../src/Keynob/Keynob.csproj)의 `Version` |
| macOS 앱 버전·빌드 번호 | [`Info.plist`](../macos/App/Info.plist)의 `CFBundleShortVersionString`·`CFBundleVersion` |
| 배포 이력 | [GitHub Releases](https://github.com/jhc3516/keynob/releases) |

MacroPad Studio 또는 이전 Keynob를 사용 중이라면 [업그레이드 안내](upgrading.md)를 확인하세요.

## 소스 구조

| 경로 | 역할 |
| --- | --- |
| [`src/Keynob/`](../src/Keynob/) | Windows WPF 앱 |
| [`src/KeyboardDeviceBridge/`](../src/KeyboardDeviceBridge/) | Windows 장치 통신 브리지 |
| [`src/CodexCliLauncher/`](../src/CodexCliLauncher/), [`src/CodexStatusHookClient/`](../src/CodexStatusHookClient/) | Windows 전용 CLI 실행기와 상태 훅 |
| [`tests/`](../tests/) | Windows 자동 시험 |
| [`macos/`](../macos/) | Swift 앱·공유 코어·CLI·시험 |
| [`scripts/`](../scripts/) | 빌드·배포·진단·시험 스크립트 |
| [`config/`](../config/), [`assets/`](../assets/) | 기본 키맵과 앱 이미지 |
| [`licenses/`](../licenses/) | Windows 배포용 서드파티 라이선스 원문 |

스크립트의 `v1`·`v2`·`v3` 이름은 기존 개발 단계의 이름이며 앱 버전 번호가 아닙니다.
경로를 참조하는 빌드·시험 도구가 있으므로 현재 이름을 유지합니다.
빌드 결과·다운로드한 의존성·로컬 설정은 Git에 포함하지 않습니다.

장치 보고서와 쓰기 절차는 [장치 프로토콜](device-protocol.md)을 참고하세요.

## 릴리스 기록

아래 문서는 각 태그 당시의 이름·경로·검증 결과를 보존합니다.
현재 소스의 사용법은 위 플랫폼별 안내를 따르세요.

- [v1.0.0-beta.2](release-notes-v1.0.0-beta.2.md): macOS 소스 추가
- [v1.0.0-beta.1](release-notes-v1.0.0-beta.1.md): Windows 베타
