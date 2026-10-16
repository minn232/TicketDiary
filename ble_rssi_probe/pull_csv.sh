#!/usr/bin/env bash
# 연결된 모든 폰에서 자동 저장된 실측 CSV를 measurements/<날짜>/로 가져옴
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")"
ADB="${ADB:-$(cygpath "$LOCALAPPDATA" 2>/dev/null)/Android/Sdk/platform-tools/adb.exe}"
SRC=/sdcard/Android/data/com.ticketdiary.ble_rssi_probe/files
OUT="measurements/$(date +%Y%m%d)"
mkdir -p "$OUT"
for d in $("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}'); do
  for f in $("$ADB" -s "$d" shell ls "$SRC" | tr -d '\r' | grep '\.csv$'); do
    "$ADB" -s "$d" pull "$SRC/$f" "$OUT/$f" >/dev/null && echo "$d -> $OUT/$f"
  done
done
