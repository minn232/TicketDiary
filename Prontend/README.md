# ticketdiary

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## 로컬 백엔드 연결

`env.example.json`을 복사해 `env.local.json`을 만들고(이 파일은 git에 커밋되지 않습니다),
필요에 맞게 `API_BASE_URL` 값을 수정한 뒤 다음과 같이 실행하세요.

```sh
cp env.example.json env.local.json  # 최초 1회
flutter run --dart-define-from-file=env.local.json
```

값을 넘기지 않으면 `http://localhost:8000`이 기본값으로 사용됩니다.
