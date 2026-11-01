package com.tiernan.music

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 公共目录下载支持（MediaStore）。
 *
 * Android 10+ (API 29+) 通过 MediaStore + IS_PENDING 写入公共目录，无需存储权限；
 * Android 9 及以下由 Dart 侧直接写公共目录路径（需 WRITE_EXTERNAL_STORAGE 运行时权限）。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.tiernan.music/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "apiLevel" -> result.success(Build.VERSION.SDK_INT)
                        "publicDir" -> {
                            val type = call.argument<String>("type") ?: ""
                            result.success(publicDir(type))
                        }
                        "insert" -> {
                            val collection = call.argument<String>("collection") ?: "audio"
                            val displayName = call.argument<String>("displayName") ?: ""
                            val relativePath = call.argument<String>("relativePath") ?: ""
                            val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                            result.success(insert(collection, displayName, relativePath, mimeType))
                        }
                        "write" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            val src = call.argument<String>("srcPath") ?: ""
                            result.success(write(Uri.parse(uri), File(src)))
                        }
                        "finalize" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            result.success(finalize(Uri.parse(uri)))
                        }
                        "delete" -> {
                            val uri = call.argument<String>("uri") ?: ""
                            result.success(delete(Uri.parse(uri)))
                        }
                        "openFile" -> {
                            val uri = call.argument<String>("uri")
                            val path = call.argument<String>("path")
                            result.success(openFile(uri, path))
                        }
                        "viewFolder" -> {
                            val path = call.argument<String>("path") ?: ""
                            result.success(viewFolder(path))
                        }
                        "query" -> {
                            val collection = call.argument<String>("collection") ?: "audio"
                            val displayName = call.argument<String>("displayName") ?: ""
                            val relativePath = call.argument<String>("relativePath") ?: ""
                            result.success(query(collection, displayName, relativePath))
                        }
                        "appendText" -> {
                            // 追加文本到公共目录文件（用于日志）。
                            // Android 10+ 走 MediaStore Downloads（无需权限）；
                            // ≤28 直接写公共 Documents 路径。
                            val displayName = call.argument<String>("displayName") ?: ""
                            val relativePath = call.argument<String>("relativePath") ?: ""
                            val content = call.argument<String>("content") ?: ""
                            val maxBytes = call.argument<Int>("maxBytes") ?: 0
                            result.success(appendText(displayName, relativePath, content, maxBytes.toLong()))
                        }
                        "publicDirWritable" -> {
                            // 该公共目录在当前系统版本下是否可直接写入
                            result.success(isPublicDirWritable(call.argument<String>("type") ?: "documents"))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("storage_error", e.message, null)
                }
            }
    }

    /** 公共目录绝对路径（仅 API <= 28 有意义） */
    private fun publicDir(type: String): String? {
        val dir = when (type) {
            "music" -> Environment.DIRECTORY_MUSIC
            "pictures" -> Environment.DIRECTORY_PICTURES
            "movies" -> Environment.DIRECTORY_MOVIES
            "documents" -> Environment.DIRECTORY_DOCUMENTS
            "downloads" -> Environment.DIRECTORY_DOWNLOADS
            else -> return null
        }
        return Environment.getExternalStoragePublicDirectory(dir).absolutePath
    }

    /** 用其它应用打开文件（优先 MediaStore Uri，回退 FileProvider） */
    private fun openFile(uri: String?, path: String?): Boolean {
        val intent = Intent(Intent.ACTION_VIEW)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (!uri.isNullOrEmpty()) {
            intent.setDataAndType(Uri.parse(uri), guessMime(uri, path))
        } else if (!path.isNullOrEmpty()) {
            val file = File(path)
            if (!file.exists()) return false
            val fileUri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            intent.setDataAndType(fileUri, guessMime(null, path))
        } else {
            return false
        }
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 在文件管理器中打开所在目录 */
    private fun viewFolder(path: String): Boolean {
        if (path.isEmpty()) return false
        val file = File(path)
        if (!file.exists()) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW)
        intent.setDataAndType(uri, "resource/folder")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            try {
                val dirIntent = Intent(Intent.ACTION_VIEW)
                dirIntent.setDataAndType(Uri.fromFile(file), "resource/folder")
                dirIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(dirIntent)
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    /** 公共目录在当前系统版本下是否可直接写文件 */
    private fun isPublicDirWritable(type: String): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return false
        val dir = when (type) {
            "music" -> Environment.DIRECTORY_MUSIC
            "pictures" -> Environment.DIRECTORY_PICTURES
            "movies" -> Environment.DIRECTORY_MOVIES
            "documents" -> Environment.DIRECTORY_DOCUMENTS
            "downloads" -> Environment.DIRECTORY_DOWNLOADS
            else -> return false
        }
        val path = File(Environment.getExternalStoragePublicDirectory(dir), "probe")
        return try {
            path.parentFile?.mkdirs()
            path.writeText("")
            path.delete()
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 追加文本到公共目录文件（用于日志）。
     *
     * Android 10+：MediaStore.Files + RELATIVE_PATH（无需任何权限）。
     *   RELATIVE_PATH 是**相对于 collection 根**的，所以要用 Files collection
     *   才能真正落在 /sdcard/Documents/xxx；用 Downloads collection 会落到
     *   /sdcard/Download/xxx。
     *   先按 DISPLAY_NAME + RELATIVE_PATH 查已有文件，命中则读旧内容再整份重写；
     *   未命中走 IS_PENDING 插入流程。
     *   超过 maxBytes 时丢弃旧内容（等价轮转）。
     * ≤28：直接追加写公共 Documents 路径（需 WRITE_EXTERNAL_STORAGE）。
     *
     * @return 实际写入位置（失败返回 null）
     */
    private fun appendText(
        displayName: String,
        relativePath: String,
        content: String,
        maxBytes: Long
    ): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val filesUri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                var existing = query(filesUri.toString(), displayName, relativePath)
                if (existing == null) {
                    // Files collection 不支持时回退 Downloads（落在 /sdcard/Download）
                    existing = query(MediaStore.Downloads.EXTERNAL_CONTENT_URI.toString(), displayName, relativePath)
                }
                if (existing != null) {
                    val uri = Uri.parse(existing)
                    var old = try {
                        contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
                    } catch (e: Exception) { "" }
                    if (maxBytes > 0 &&
                        old.toByteArray(Charsets.UTF_8).size + content.toByteArray(Charsets.UTF_8).size > maxBytes
                    ) {
                        old = ""
                    }
                    val os = contentResolver.openOutputStream(uri, "rwt") ?: return null
                    os.use { it.write((old + content).toByteArray(Charsets.UTF_8)) }
                    // 重写后必须补一次 IS_PENDING=0：上次进程若在 finalize 前被杀，
                    // 文件会一直处于 pending 状态（文件管理器里看不到）。
                    val done = ContentValues()
                    done.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, done, null, null)
                    return "/sdcard/$relativePath"
                }

                val values = ContentValues()
                values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                values.put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                values.put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                values.put(MediaStore.MediaColumns.IS_PENDING, 1)
                val uri = contentResolver.insert(filesUri, values)
                    ?: contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return null
                val os = contentResolver.openOutputStream(uri, "w") ?: return null
                os.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                val done = ContentValues()
                done.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, done, null, null)
                "/sdcard/$relativePath"
            } else {
                val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
                // relativePath 形如 "Documents/<folder>/<logs>"，而 base 已经是 Documents 根，
                // 直接拼接会得到 /sdcard/Documents/Documents/... —— 这里去掉前缀 "Documents/"。
                val relative = relativePath.removePrefix("Documents/").removePrefix("/")
                val dir = File(base, relative)
                if (!dir.exists()) dir.mkdirs()
                val target = File(dir, displayName)
                if (maxBytes > 0 && target.exists() &&
                    target.length() + content.toByteArray(Charsets.UTF_8).size > maxBytes
                ) {
                    val rotated = File(dir, "$displayName.1")
                    if (rotated.exists()) rotated.delete()
                    target.renameTo(rotated)
                }
                target.appendText(content)
                dir.absolutePath
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun guessMime(uri: String?, path: String?): String {        val name = path ?: uri ?: ""
        return when {
            name.endsWith(".mp3") -> "audio/mpeg"
            name.endsWith(".m4a") -> "audio/mp4"
            name.endsWith(".flac") -> "audio/flac"
            name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
            name.endsWith(".png") -> "image/png"
            name.endsWith(".mp4") -> "video/mp4"
            name.endsWith(".txt") -> "text/plain"
            else -> "*/*"
        }
    }

    private fun collectionUri(collection: String): Uri {
        return when (collection) {
            "images" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            "downloads" -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            else -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
    }

    private fun insert(collection: String, displayName: String, relativePath: String, mimeType: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val values = ContentValues()
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
        values.put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
        values.put(MediaStore.MediaColumns.IS_PENDING, 1)
        val uri = contentResolver.insert(collectionUri(collection), values) ?: return null
        return uri.toString()
    }

    private fun write(uri: Uri, src: File): Boolean {
        if (!src.exists()) return false
        val os = contentResolver.openOutputStream(uri, "w") ?: return false
        os.use { out ->
            src.inputStream().use { it.copyTo(out) }
        }
        return true
    }

    private fun finalize(uri: Uri): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        val values = ContentValues()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        contentResolver.update(uri, values, null, null)
        return true
    }

    private fun delete(uri: Uri): Boolean {
        return try {
            contentResolver.delete(uri, null, null) > 0
        } catch (e: Exception) {
            false
        }
    }

    private fun query(collection: String, displayName: String, relativePath: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val target = if (collection.startsWith("content://")) {
            Uri.parse(collection)
        } else {
            collectionUri(collection)
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH
        )
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val args = arrayOf(displayName, "$relativePath%")
        contentResolver.query(target, projection, selection, args, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                return android.content.ContentUris.withAppendedId(target, id).toString()
            }
        }
        return null
    }
}
