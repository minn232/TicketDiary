package com.example.ticketdiary

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // windowSoftInputMode만으로는 최신 안드로이드(edge-to-edge 강제 버전)
    // 실기기에서 키보드가 뜰 때 창이 그대로 줄어드는 문제가 재현돼,
    // decorFitsSystemWindows를 꺼서 창 크기 자체를 안 건드리게 함.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }
}
