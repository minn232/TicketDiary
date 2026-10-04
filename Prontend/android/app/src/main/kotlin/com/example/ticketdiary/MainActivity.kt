package com.example.ticketdiary

import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    // windowSoftInputMode만으로는 최신 안드로이드(edge-to-edge 강제 버전)
    // 실기기에서 키보드가 뜰 때 창이 그대로 줄어드는 문제가 재현돼,
    // decorFitsSystemWindows를 꺼서 창 크기 자체를 안 건드리게 함.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    /** 공연후 페이지 공유: 인스타/X/카카오톡을 앱 선택창 없이 바로 엶. */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ticketdiary/share_targets")
            .setMethodCallHandler { call, result ->
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                when (call.method) {
                    "installed" -> result.success(
                        mapOf(
                            "instagram" to isInstalled(INSTAGRAM),
                            "x" to isInstalled(X),
                            "kakao" to isInstalled(KAKAO),
                        )
                    )
                    "instagramStory" -> result.success(
                        shareToInstagramStory(
                            paths.first(),
                            call.argument<String>("appId")!!,
                            call.argument<String>("topColor")!!,
                            call.argument<String>("bottomColor")!!,
                        )
                    )
                    // 한 장은 공식 피드 동작, 여러 장(캐러셀)은 피드 화면을 지정.
                    "instagramFeed" -> result.success(
                        if (paths.size == 1) {
                            sendImages(paths, INSTAGRAM, action = "com.instagram.share.ADD_TO_FEED")
                        } else {
                            sendImages(
                                paths,
                                INSTAGRAM,
                                "com.instagram.share.handleractivity.ShareHandlerActivityMultipleFeedAlias",
                            )
                        }
                    )
                    // X는 DM과 글쓰기 두 곳이 받아서 글쓰기 화면을 지정.
                    "x" -> result.success(
                        sendImages(paths, X, "com.twitter.composer.ComposerActivity")
                    )
                    "kakaoPhoto" -> result.success(sendImages(paths, KAKAO))
                    else -> result.notImplemented()
                }
            }
    }

    private fun isInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun uriOf(path: String): Uri =
        FileProvider.getUriForFile(this, "$packageName.story_provider", File(path))

    /** [pkg] 앱으로 이미지 전송. [component](비공식 앱 내부 화면)가 없으면 [pkg]만 지정. */
    private fun sendImages(
        paths: List<String>,
        pkg: String,
        component: String? = null,
        action: String? = null,
    ): Boolean {
        val uris = paths.map(::uriOf)
        val intent = Intent(
            action ?: if (uris.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND
        ).apply {
            type = "image/png"
            setPackage(pkg)
            if (uris.size > 1) {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            } else {
                putExtra(Intent.EXTRA_STREAM, uris.first())
            }
            clipData = ClipData.newRawUri(null, uris.first()).also { clip ->
                uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (component != null) {
            val exact = Intent(intent).setComponent(ComponentName(pkg, component))
            if (packageManager.resolveActivity(exact, 0) != null) {
                startActivity(exact)
                return true
            }
        }
        if (packageManager.resolveActivity(intent, 0) == null) return false
        startActivity(intent)
        return true
    }

    /** 이미지를 스티커로 얹은 인스타 스토리 편집 화면 열기 (Meta 공식 인텐트). */
    private fun shareToInstagramStory(
        path: String,
        appId: String,
        topColor: String,
        bottomColor: String,
    ): Boolean {
        val uri = uriOf(path)
        val intent = Intent("com.instagram.share.ADD_TO_STORY").apply {
            putExtra("source_application", appId)
            type = "image/png"
            putExtra("interactive_asset_uri", uri)
            putExtra("top_background_color", topColor)
            putExtra("bottom_background_color", bottomColor)
        }
        grantUriPermission(INSTAGRAM, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (packageManager.resolveActivity(intent, 0) == null) return false
        startActivity(intent)
        return true
    }

    private companion object {
        const val INSTAGRAM = "com.instagram.android"
        const val X = "com.twitter.android"
        const val KAKAO = "com.kakao.talk"
    }
}
