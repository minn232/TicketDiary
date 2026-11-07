# Ticket Diary 프런트엔드

Flutter 앱입니다. 서버 설정과 Android 푸시 준비 절차는 [프로젝트 README](../README.md)를 참고하세요.

## 실행

이 디렉터리(`Prontend`)에서 실행합니다. 최초 설정 때만 `env.example.json`을 `env.local.json`으로 복사하고 `API_BASE_URL`을 수정하세요. 기존 파일에는 덮어쓰지 않습니다.

```bash
flutter pub get
flutter devices
flutter run -d "기기_ID" --dart-define-from-file=env.local.json
```

환경값을 넘기지 않으면 API 주소는 `http://localhost:8000/api/v1`입니다. 실제 휴대폰에서 `localhost`는 휴대폰 자신을 가리키므로, 접근 가능한 개발 서버 주소를 사용해야 합니다.

## 코드 구조

| 경로 | 역할 |
| --- | --- |
| `lib/main.dart`, `lib/main/` | 앱 초기화, 라우팅, 화면 방향 정책 |
| `lib/screen/` | 다이어리·소식·결산·설정 화면과 상세 오버레이 |
| `lib/widgets/` | 화면 구성 요소, 공통 UI, 애니메이션 |
| `lib/widgets/member_settings_sheet.dart` | 로그인·로그아웃·프로필 편집 진입 시트 |
| `lib/widgets/local_profile_editor.dart` | 계정별 기기 내 프로필 편집 |
| `lib/widgets/audio_volume_settings.dart` | 효과음·미리듣기 개별 볼륨 UI |
| `lib/services/` | API 통신, 기기 저장소, 오디오·푸시 연동 |
| `lib/models/` | API 데이터와 화면 데이터 모델 |
| `test/` | 모델·서비스·위젯 회귀 테스트 |
| `android/`, `ios/` | 플랫폼 설정과 네이티브 연동 |
| `assets/` | 폰트·이미지·효과음·지도 데이터 |

## 검사

```bash
flutter analyze --no-pub
flutter test --no-pub
```

빌드 산출물과 외부 SDK 소스(`build/`, `.dart_tool/`, Pods 등)는 정적 분석에서 제외합니다. 테스트는 실제 서버 푸시 발송이나 카카오 로그인을 대신하지 않으므로, 해당 기능은 설정 파일을 준비한 뒤 실기기에서 확인해야 합니다.

### 전체 라인 커버리지

```bash
python3 tool/check_coverage.py
```

`lib/`의 모든 Dart 파일을 포함해 전체 테스트를 실행하고, 폴더별 라인 커버리지를 출력합니다. 테스트가 직접 불러오지 않는 파일도 분모에 포함하기 위해 임시 import 테스트를 만들고 실행 후 제거합니다. 결과는 `coverage/lcov.info`에 저장됩니다. Android/iOS 네이티브 코드는 포함하지 않습니다.

기본 기준은 70%이며 `--minimum 75`처럼 변경할 수 있습니다. 테스트 실패, 측정에서 누락된 파일, 기준 미달 중 하나라도 있으면 명령은 실패 상태로 종료합니다. 테스트가 실패해도 보고서가 생성되면 수치는 출력하되, 실패한 테스트에서 실행된 줄도 포함됨을 표시합니다.
