package com.example.ticketdiary

import androidx.core.content.FileProvider

/** 인스타/X/카카오톡으로 넘기는 공유 이미지용 (다른 플러그인 FileProvider와 이름 충돌 방지). */
class StoryFileProvider : FileProvider()
