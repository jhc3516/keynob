# Keynob v1.0.0-beta.4

공개 문서와 소스 이력을 정리한 베타입니다. 앱 기능은 beta.3과 같습니다.

## 다운로드

- Windows 10/11 x64: `Keynob-v1.0.0-beta.4-win-x64.zip`을 새 폴더에 풀고 `Keynob.exe`를 실행하세요.
- Windows·macOS 소스: `Keynob-v1.0.0-beta.4-source.zip` 또는 이 릴리스의 자동 `Source code` 자료를 받으세요. 모두 같은 태그의 소스입니다.
- 직접 제공하는 ZIP에는 각각 `.zip.sha256` 체크섬이 있습니다.
- macOS는 `./scripts/build-macos-app.sh`로 로컬 빌드합니다. 공증된 Mac 실행 파일은 제공하지 않습니다.

## 변경 내용

- 사용자 안내에 포함됐던 개인 개발용 문서와 링크를 공개 소스 및 관련 과거 이력에서 제외했습니다.
- README의 다운로드 링크와 Windows 버전을 beta.4로 갱신했습니다.
- 기존 설정·백업·훅 호환 경로와 앱 동작은 유지합니다.

기존 Git 체크아웃은 이력 변경으로 커밋 ID가 달라졌습니다. 로컬 작업을 보관하고 새로 clone하세요.
앱 사용자에게는 재설정이 필요하지 않습니다. 이전 절차는
[업그레이드 안내](https://github.com/jhc3516/keynob/blob/v1.0.0-beta.4/docs/upgrading.md)를 확인하세요.

## 검증과 제한

- Windows portable 빌드, 설정 회귀, 실행기 검사 및 패키지 준비도를 확인합니다.
- Windows 실행 파일은 코드 서명되지 않았습니다.
- Codex CLI 전용 실행기는 0.158.0에서 검증한 `--no-daemon`을 사용합니다. 구버전 호환성은 미검증입니다.
- Codex 상태 훅은 새 CLI의 `/hooks`에서 사용자가 직접 검토하고 신뢰해야 합니다.
- 실물 키·LED, 별도 Windows PC 및 macOS 빌드는 이번 문서 정리 릴리스에서 다시 검증하지 않습니다.
