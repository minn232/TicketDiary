<#
.SYNOPSIS
    Prontend 릴리즈 APK를 빌드해서 USB로 연결된 실기기에 바로 설치한다.

.DESCRIPTION
    -dart-define=API_BASE_URL을 빼먹으면 앱이 기기 자신의 localhost를 보게 돼서 서버 연결이
    통째로 안 되는 사고가 있었음(2026-08-18) - 이 스크립트는 항상 명시적으로 넘긴다.
    기기가 여러 대 연결돼 있으면 -DeviceId로 지정해야 하고, 안 주면 목록만 보여주고 중단한다.
    이 스크립트는 backend/scripts에 있지만 대상은 Prontend라 경로를 하드코딩해서 참조한다.

.PARAMETER ApiBaseUrl
    빌드에 심을 백엔드 주소. 기본값은 운영 서버.

.PARAMETER DeviceId
    설치 대상 adb 기기 ID. 생략하면 연결된 기기가 정확히 1대일 때만 자동 선택.

.EXAMPLE
    .\build_and_install_release.ps1
    .\build_and_install_release.ps1 -DeviceId R54TB00PZ2W
    .\build_and_install_release.ps1 -ApiBaseUrl http://localhost:8000/api/v1
#>
param(
    [string]$ApiBaseUrl = "https://ticket-diary.com/api/v1",
    [string]$DeviceId
)

$ErrorActionPreference = "Stop"

$adb = "C:\Users\asrik\AppData\Local\Android\Sdk\platform-tools\adb.exe"
$prontendRoot = "C:\Users\asrik\Documents\Python\TicketDiary\Prontend"
Set-Location $prontendRoot

# 기기 선택. @()로 강제로 배열화하지 않으면 기기가 정확히 1대일 때 파이프라인이 배열이 아닌
# 문자열 하나로 풀려서(PowerShell의 단일 요소 언롤링), 아래 [0] 인덱싱이 배열 첫 원소가 아니라
# 그 문자열의 첫 글자(예: "R54TB00PZ2W" -> "R")를 가져오는 버그가 남 (실측 확인)
$deviceLines = @(& $adb devices -l | Select-Object -Skip 1 | Where-Object { $_ -match '\S' -and $_ -notmatch 'List of devices' })
$deviceIds = @($deviceLines | ForEach-Object { ($_ -split '\s+')[0] })

if (-not $DeviceId) {
    if ($deviceIds.Count -eq 0) {
        Write-Error "연결된 기기가 없습니다. USB 디버깅 연결 상태를 확인해주세요."
    } elseif ($deviceIds.Count -gt 1) {
        Write-Host "연결된 기기가 여러 대입니다. -DeviceId로 지정해주세요:"
        $deviceLines | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    $DeviceId = $deviceIds[0]
}
Write-Host "설치 대상 기기: $DeviceId"

# 빌드 전 gradle.properties 상태 기록 - flutter build가 매번 마이그레이터 안내 줄을 자동으로
# 끼워 넣는 부수효과가 있어서(실측 확인, 기능과 무관), 빌드 후 그 노이즈만
# 걸러서 되돌리기 위함. 이후 단계에서 실패해도(빌드/설치 오류) 되돌림이 항상 실행되도록
# try/finally로 감쌈 - 안 그러면 실패한 시도의 흔적이 git 작업 트리에 그대로 남음(실측 확인).
# 판단은 줄 단위 배열로 비교(파일 자체의 줄바꿈 방식이 LF/CRLF 어느 쪽이든 안전), 복원은 원본
# 바이트 그대로(-Raw) 써서 줄바꿈 방식이 바뀌는 곁다리 diff가 안 생기게 함
$gradlePropsPath = "android\gradle.properties"
$beforeGradleProps = Get-Content $gradlePropsPath -Raw
$beforeGradleLines = @(Get-Content $gradlePropsPath)

try {
    Write-Host "릴리즈 빌드 시작 (API_BASE_URL=$ApiBaseUrl)..."
    flutter build apk --release --dart-define="API_BASE_URL=$ApiBaseUrl"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "flutter build apk 실패 (exit $LASTEXITCODE)"
    }

    $apkPath = "build\app\outputs\flutter-apk\app-release.apk"
    if (-not (Test-Path $apkPath)) {
        Write-Error "빌드 결과물을 찾을 수 없습니다: $apkPath"
    }

    Write-Host "설치 중..."
    & $adb -s $DeviceId install -r $apkPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "adb install 실패 (exit $LASTEXITCODE)"
    }

    Write-Host "완료: $DeviceId 에 설치됨."
} finally {
    # 마이그레이터가 gradle.properties를 건드렸다면(기능과 무관한 안내 줄 추가) 원래대로
    # 되돌림. 줄이 하나라도 지워졌거나, 새로 추가된 줄 중 마이그레이터 패턴이 아닌 게 있으면
    # (사람이 직접 고친 경우 등) 실질적인 변경으로 보고 안전하게 그대로 두고 알림만 함
    $afterGradleLines = @(Get-Content $gradlePropsPath)
    $diffResult = @(Compare-Object $beforeGradleLines $afterGradleLines)
    if ($diffResult) {
        $removedLines = @($diffResult | Where-Object { $_.SideIndicator -eq '<=' })
        $addedLines = @($diffResult | Where-Object { $_.SideIndicator -eq '=>' })
        $nonNoiseAdded = @($addedLines | Where-Object {
            $_.InputObject -notmatch '^#.*(builtInKotlin|newDsl)' -and $_.InputObject -notmatch '^android\.(builtInKotlin|newDsl)=\w+$'
        })

        if ($removedLines.Count -eq 0 -and $nonNoiseAdded.Count -eq 0) {
            Set-Content -Path $gradlePropsPath -Value $beforeGradleProps -NoNewline
            Write-Host "gradle.properties에 낀 마이그레이터 안내 줄을 되돌렸습니다."
        } else {
            Write-Warning "gradle.properties가 예상 밖의 내용으로 바뀌었습니다 - 직접 확인해주세요(자동으로 안 되돌림)."
        }
    }
}
