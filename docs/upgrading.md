# 이전 버전에서 업그레이드

[문서 목록](README.md)

MacroPad Studio 또는 이전 Keynob를 사용하던 경우에만 참고하세요. 처음 설치할 때는
[시작 안내](../README.md#설치하기)를 따르면 됩니다.

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
