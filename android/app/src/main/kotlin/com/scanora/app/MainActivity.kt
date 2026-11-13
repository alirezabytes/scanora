package com.scanora.app

import android.Manifest
import android.app.AppOpsManager
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PointF
import android.graphics.pdf.PdfRenderer
import android.media.FaceDetector
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import com.googlecode.tesseract.android.TessBaseAPI
import com.reecedunn.espeak.SpeechSynthesis
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

private object LocalCrashReport {
    private var installed = false
    @Synchronized
    fun install(directory: File) {
        if (installed) return
        val previous = Thread.getDefaultUncaughtExceptionHandler() ?: return
        installed = true
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                directory.mkdirs()
                val report = File(directory, "android-errors.log")
                if (report.exists() && report.length() > 256 * 1024) {
                    val old = File(directory, "android-errors.previous.log")
                    old.delete()
                    report.renameTo(old)
                }
                // Exception messages can contain personal text. Save types and
                // stack locations only, then preserve Android's normal handler.
                report.appendText("${System.currentTimeMillis()} ${error.javaClass.name}\n" +
                    error.stackTrace.take(20).joinToString("\n") + "\n")
            } catch (_: Throwable) {}
            previous.uncaughtException(thread, error)
        }
    }
}

class MainActivity : FlutterActivity() {
    private val cameraPermissionRequest = 52041
    private var cameraPermissionResult: MethodChannel.Result? = null
    private var cameraPermissionInFlight = false
    private var activityResumed = false
    private val CHANNEL = "com.scanora.app/native"
    private var methodChannel: MethodChannel? = null
    private var pendingSharedImage: Map<String, Any?>? = null
    private val pendingSharedFiles = mutableListOf<List<String>>()
    private val shareExecutor = Executors.newSingleThreadExecutor()
    private val executor = Executors.newSingleThreadExecutor()
    private val ttsExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var tessApi: TessBaseAPI? = null
    private var initializedDataPath: String? = null
    private var initializedLanguage: String? = null
    private var espeakSynth: SpeechSynthesis? = null
    private var initializedEspeakPath: String? = null
    private var pageFlipPlayer: MediaPlayer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent, notifyFlutter = true)
    }

    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    private fun cameraAccess(): String {
        if (!hasCameraPermission()) return "denied"
        val appOps = getSystemService(AppOpsManager::class.java) ?: return "allowed"
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_CAMERA, Process.myUid(), packageName)
        } else {
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_CAMERA, Process.myUid(), packageName)
        }
        return if (mode == AppOpsManager.MODE_IGNORED || mode == AppOpsManager.MODE_ERRORED)
            "blocked" else "allowed"
    }

    private fun reportCameraAccess(result: MethodChannel.Result, status: String, stage: String) {
        Log.i("ScanoraCamera", "access uid=${Process.myUid()} stage=$stage status=$status")
        result.success(status)
    }

    override fun onPostResume() {
        super.onPostResume()
        activityResumed = true
        requestCameraPermissionWhenReady()
    }

    override fun onPause() {
        activityResumed = false
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) requestCameraPermissionWhenReady()
    }

    private fun requestCameraPermissionWhenReady() {
        val result = cameraPermissionResult ?: return
        if (cameraPermissionInFlight || !activityResumed || !hasWindowFocus()) return
        val status = cameraAccess()
        if (status != "denied") {
            cameraPermissionResult = null
            reportCameraAccess(result, status, "beforePrompt")
            return
        }
        cameraPermissionInFlight = true
        try {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), cameraPermissionRequest)
        } catch (_: Exception) {
            cameraPermissionResult = null
            cameraPermissionInFlight = false
            result.error("CAMERA_PERMISSION_REQUEST", "Could not request camera access", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != cameraPermissionRequest) return
        val pending = cameraPermissionResult
        cameraPermissionResult = null
        cameraPermissionInFlight = false
        // The callback can arrive after a profile or policy change. Trust the
        // grant and app-op for this process, rather than the dialog result alone.
        if (pending != null) reportCameraAccess(pending, cameraAccess(), "afterPrompt")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LocalCrashReport.install(File(applicationContext.filesDir, "diagnostics"))
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            if (isDestroyed || isFinishing) {
                result.error("ACTIVITY_CLOSED", "The current screen has closed", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "cameraPermission" -> {
                    val status = cameraAccess()
                    if (status != "denied" || call.argument<Boolean>("request") != true ||
                        cameraPermissionResult != null) {
                        reportCameraAccess(result, status, "check")
                    } else {
                        cameraPermissionResult = result
                        requestCameraPermissionWhenReady()
                    }
                }
                "beginDocumentProcessing" -> {
                    val id = call.argument<Int>("id")
                    val persian = call.argument<Boolean>("persian") ?: false
                    result.success(id != null && DocumentProcessingService.begin(this, id, persian))
                }
                "finishDocumentProcessing" -> {
                    call.argument<Int>("id")?.let { DocumentProcessingService.finish(it) }
                    result.success(null)
                }
                "getInitialSharedImage" -> {
                    val image = pendingSharedImage
                    pendingSharedImage = null
                    result.success(image)
                }
                "takeSharedFiles" -> {
                    val batches = pendingSharedFiles.toList()
                    pendingSharedFiles.clear()
                    result.success(batches)
                }
                "getAndroidDeviceId" -> {
                    val androidId = try {
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: "ANDROID-UNKNOWN"
                    } catch (_: Exception) {
                        "ANDROID-UNKNOWN"
                    }
                    result.success(androidId)
                }
                "getPackageFirstInstallTime" -> {
                    val installTime = try {
                        val pkgInfo = packageManager.getPackageInfo(packageName, 0)
                        pkgInfo.firstInstallTime
                    } catch (_: Exception) {
                        0L
                    }
                    result.success(installTime)
                }
                "savePersistentLicenseState" -> {
                    val fileName = call.argument<String>("fileName") ?: ".scn_sys_state.dat"
                    val content = call.argument<String>("content") ?: ""
                    executor.execute {
                        savePersistentLicToSharedStorage(fileName, content)
                        mainHandler.post {
                            result.success(true)
                        }
                    }
                }
                "loadPersistentLicenseState" -> {
                    val fileName = call.argument<String>("fileName") ?: ".scn_sys_state.dat"
                    executor.execute {
                        val loaded = loadPersistentLicFromSharedStorage(fileName)
                        mainHandler.post {
                            result.success(loaded)
                        }
                    }
                }
                "playPageFlipSound" -> {
                    playPageFlipAsset()
                    result.success(true)
                }
                "openUrlInBrowser" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(browserIntent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "bringAppToFront" -> {
                    try {
                        val reopenIntent = Intent(this, MainActivity::class.java).apply {
                            addFlags(
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_NEW_TASK
                            )
                        }
                        startActivity(reopenIntent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "recognizeCameraLuma" -> {
                    val pixels = call.argument<ByteArray>("pixels")
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    val dataPath = call.argument<String>("dataPath")
                    if (pixels == null || width < 16 || height < 16 ||
                        width > 1920 || height > 1920 ||
                        pixels.size != width * height || dataPath == null) {
                        result.error("OCR_INPUT", "Invalid camera analysis frame.", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val recognized = runCameraLuma(pixels, width, height, dataPath)
                            mainHandler.post {
                                result.success(mapOf("text" to recognized.first,
                                    "confidence" to recognized.second))
                            }
                        } catch (error: Throwable) {
                            mainHandler.post {
                                result.error("OCR_FAILED", error.message, null)
                            }
                        }
                    }
                }
                "recognizeTextTesseract", "recognizeTextTesseractWithConfidence" -> {
                    val includeConfidence = call.method == "recognizeTextTesseractWithConfidence"
                    val imagePath = call.argument<String>("imagePath")
                    val dataPath = call.argument<String>("dataPath")
                    val language = call.argument<String>("language") ?: "fas+eng"
                    val pageSegMode = call.argument<Int>("pageSegMode") ?: TessBaseAPI.PageSegMode.PSM_AUTO
                    val disableDictionary = call.argument<Boolean>("disableDictionary") ?: false
                    val charWhitelist = call.argument<String>("charWhitelist") ?: ""
                    val adaptiveThreshold = call.argument<Boolean>("adaptiveThreshold") ?: false
                    val includeLayout = call.argument<Boolean>("includeLayout") ?: false
                    if (imagePath == null || dataPath == null) {
                        result.error("OCR_INPUT", "Missing OCR image or language-data path.", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                        val recognized = runTesseractOcr(
                            imagePath,
                            dataPath,
                            language,
                            pageSegMode,
                            disableDictionary,
                            charWhitelist,
                            adaptiveThreshold,
                            includeLayout
                        )
                        mainHandler.post {
                            result.success(if (includeConfidence) mapOf(
                                "text" to recognized.first,
                                "confidence" to recognized.second,
                                "lines" to recognized.third
                            ) else recognized.first)
                        }
                        } catch (error: Throwable) {
                            mainHandler.post { result.error("OCR_FAILED", error.message ?: "Tesseract OCR failed.", null) }
                        }
                    }
                }
                "detectFaces" -> {
                    val imageBytes = call.argument<ByteArray>("imageBytes")
                    if (imageBytes == null || imageBytes.isEmpty()) {
                        result.success(emptyList<Map<String, Double>>())
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        val faces = runAndroidFaceDetector(imageBytes)
                        mainHandler.post {
                            result.success(faces)
                        }
                    }
                }
                "renderPdfPage" -> {
                    val pdfPath = call.argument<String>("pdfPath")
                    val pageIndex = call.argument<Int>("pageIndex") ?: 0
                    if (pdfPath == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        val pngBytes = renderPdfPageToPng(pdfPath, pageIndex)
                        mainHandler.post {
                            result.success(pngBytes)
                        }
                    }
                }
                "espeakSpeak" -> {
                    val dataPath = call.argument<String>("dataPath")
                    val text = call.argument<String>("text") ?: ""
                    val voice = call.argument<String>("voice") ?: "en"
                    val rate = call.argument<Int>("rate") ?: 175
                    val pitch = call.argument<Int>("pitch") ?: 50
                    val pitchRange = call.argument<Int>("pitchRange") ?: 50
                    val volume = call.argument<Int>("volume") ?: 100
                    val wordGap = call.argument<Int>("wordGap") ?: 5
                    val punctuation = call.argument<Int>("punctuation") ?: 0
                    val capitalsMode = call.argument<Int>("capitalsMode") ?: 0
                    val customPunctChars = call.argument<String>("customPunctChars") ?: ""
                    val ssml = call.argument<Boolean>("ssml") ?: false
                    if (dataPath == null || text.isBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        espeakSynth?.stop()
                    } catch (_: Throwable) {}
                    ttsExecutor.execute {
                        val ok = runEspeakSpeak(
                            dataPath,
                            text,
                            voice,
                            rate,
                            pitch,
                            pitchRange,
                            volume,
                            wordGap,
                            punctuation,
                            capitalsMode,
                            customPunctChars,
                            ssml
                        )
                        mainHandler.post {
                            result.success(ok)
                        }
                    }
                }
                "espeakStop" -> {
                    try {
                        espeakSynth?.stop()
                    } catch (_: Throwable) {}
                    result.success(true)
                }
                "espeakSynthesizeToWav" -> {
                    val dataPath = call.argument<String>("dataPath")
                    val text = call.argument<String>("text") ?: ""
                    val voice = call.argument<String>("voice") ?: "en"
                    val rate = call.argument<Int>("rate") ?: 175
                    val pitch = call.argument<Int>("pitch") ?: 50
                    val pitchRange = call.argument<Int>("pitchRange") ?: 50
                    val volume = call.argument<Int>("volume") ?: 100
                    val wordGap = call.argument<Int>("wordGap") ?: 5
                    val punctuation = call.argument<Int>("punctuation") ?: 0
                    val capitalsMode = call.argument<Int>("capitalsMode") ?: 0
                    val customPunctChars = call.argument<String>("customPunctChars") ?: ""
                    val ssml = call.argument<Boolean>("ssml") ?: false
                    if (dataPath == null || text.isBlank()) {
                        result.success(ByteArray(0))
                        return@setMethodCallHandler
                    }
                    ttsExecutor.execute {
                        val wavBytes = runEspeakToWav(
                            dataPath,
                            text,
                            voice,
                            rate,
                            pitch,
                            pitchRange,
                            volume,
                            wordGap,
                            punctuation,
                            capitalsMode,
                            customPunctChars,
                            ssml
                        )
                        mainHandler.post {
                            result.success(wavBytes)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playPageFlipAsset() {
        try {
            pageFlipPlayer?.release()
            pageFlipPlayer = null
            val player = MediaPlayer()
            val afd = try {
                assets.openFd("flutter_assets/assets/audio/pageFlip.mp3")
            } catch (_: Exception) {
                assets.openFd("flutter_assets/audio/pageFlip.mp3")
            }
            player.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            player.setOnCompletionListener { mp ->
                try {
                    mp.release()
                } catch (_: Exception) {}
            }
            player.prepare()
            player.start()
            pageFlipPlayer = player
        } catch (_: Exception) {
        }
    }

    private fun savePersistentLicToSharedStorage(fileName: String, content: String) {
        if (content.isBlank()) return
        val bytes = content.toByteArray(Charsets.UTF_8)

        // 1. Direct shared directories (survives Clear Cache & Clear Data)
        val dirs = listOf(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        )
        for (dir in dirs) {
            try {
                if (!dir.exists()) dir.mkdirs()
                File(dir, fileName).writeText(content, Charsets.UTF_8)
            } catch (_: Exception) {}
        }

        // 2. Android 10+ MediaStore.Downloads (survives Clear Cache, Clear Data & Uninstall)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = contentResolver
                val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val projection = arrayOf(MediaStore.Downloads._ID)
                val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
                val selectionArgs = arrayOf(fileName)

                resolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        val existingUri = ContentUris.withAppendedId(collection, id)
                        try {
                            resolver.openOutputStream(existingUri, "wt")?.use { out ->
                                out.write(bytes)
                                out.flush()
                            }
                            return
                        } catch (_: Exception) {}
                    }
                }

                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                }
                val uri = resolver.insert(collection, values)
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { out ->
                        out.write(bytes)
                        out.flush()
                    }
                }
            } catch (_: Exception) {}
        }
    }

    private fun loadPersistentLicFromSharedStorage(fileName: String): String? {
        // 1. Check direct shared directories
        val dirs = listOf(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
        )
        for (dir in dirs) {
            try {
                val f = File(dir, fileName)
                if (f.exists() && f.length() > 0) {
                    val txt = f.readText(Charsets.UTF_8).trim()
                    if (txt.isNotEmpty()) return txt
                }
            } catch (_: Exception) {}
        }

        // 2. Check MediaStore.Downloads on Android 10+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val resolver = contentResolver
                val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val projection = arrayOf(MediaStore.Downloads._ID)
                val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
                val selectionArgs = arrayOf(fileName)

                resolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        val uri = ContentUris.withAppendedId(collection, id)
                        resolver.openInputStream(uri)?.use { input ->
                            val txt = input.bufferedReader(Charsets.UTF_8).readText().trim()
                            if (txt.isNotEmpty()) return txt
                        }
                    }
                }
            } catch (_: Exception) {}
        }
        return null
    }

    @Synchronized
    private fun getOrInitEspeak(dataPath: String): SpeechSynthesis {
        if (espeakSynth == null) {
            espeakSynth = SpeechSynthesis()
        }
        if (initializedEspeakPath != dataPath) {
            espeakSynth!!.ensureInitialized(dataPath)
            initializedEspeakPath = dataPath
        }
        return espeakSynth!!
    }

    private fun runEspeakSpeak(
        dataPath: String,
        text: String,
        voice: String,
        rate: Int,
        pitch: Int,
        pitchRange: Int,
        volume: Int,
        wordGap: Int,
        punctuation: Int,
        capitalsMode: Int,
        customPunctChars: String,
        ssml: Boolean = false
    ): Boolean {
        return try {
            val synth = getOrInitEspeak(dataPath)
            synth.ensureInitialized(dataPath)
            synth.configureVoice(
                voice,
                rate,
                volume,
                pitch,
                pitchRange,
                wordGap,
                punctuation,
                capitalsMode,
                customPunctChars
            )
            synth.speakLive(text, ssml)
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun runEspeakToWav(
        dataPath: String,
        text: String,
        voice: String,
        rate: Int,
        pitch: Int,
        pitchRange: Int,
        volume: Int,
        wordGap: Int,
        punctuation: Int,
        capitalsMode: Int,
        customPunctChars: String,
        ssml: Boolean = false
    ): ByteArray {
        return try {
            val synth = getOrInitEspeak(dataPath)
            synth.ensureInitialized(dataPath)
            synth.configureVoice(
                voice,
                rate,
                volume,
                pitch,
                pitchRange,
                wordGap,
                punctuation,
                capitalsMode,
                customPunctChars
            )
            synth.synthesizeToWav(text, ssml)
        } catch (e: Throwable) {
            ByteArray(0)
        }
    }

    private fun handleIncomingIntent(intent: Intent?, notifyFlutter: Boolean) {
        if (intent == null) return
        val action = intent.action
        val type = intent.type ?: ""
        if (action == Intent.ACTION_SEND_MULTIPLE ||
            (action == Intent.ACTION_SEND && !type.startsWith("image/"))) {
            shareExecutor.execute { stageSharedFiles(intent, type) }
            return
        }

        var imageUri: Uri? = null
        if (Intent.ACTION_SEND == action && type.startsWith("image/")) {
            imageUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
        } else if (Intent.ACTION_VIEW == action && type.startsWith("image/")) {
            imageUri = intent.data
        }

        if (imageUri != null) {
            try {
                contentResolver.openInputStream(imageUri)?.use { inputStream ->
                    val bytes = inputStream.readBytes()
                    if (bytes.isNotEmpty()) {
                        val name = runCatching {
                            contentResolver.query(imageUri, arrayOf(OpenableColumns.DISPLAY_NAME),
                                null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) cursor.getString(0) else null
                            }
                        }.getOrNull()
                        val image = mapOf("bytes" to bytes, "name" to name)
                        if (notifyFlutter && methodChannel != null) {
                            mainHandler.post {
                                methodChannel?.invokeMethod("onSharedImage", image)
                            }
                        } else {
                            pendingSharedImage = image
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun stageSharedFiles(intent: Intent, type: String) {
        val folder = File(File(cacheDir, "shared_documents"), UUID.randomUUID().toString())
        val paths = try {
            val multiple = intent.action == Intent.ACTION_SEND_MULTIPLE
            val uris = if (multiple) {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            } else {
                listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            }.ifEmpty {
                val clip = intent.clipData
                if (clip == null) emptyList() else
                    (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
            }
            check(uris.size <= 100)
            check(folder.mkdirs())
            var remainingBytes = 128L * 1024 * 1024
            if (uris.isEmpty()) {
                val text = if (!multiple && type.startsWith("text/")) {
                    intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                } else null
                check(!text.isNullOrBlank() && text.length <= 1_000_000)
                val destination = File(folder, "Shared text.txt")
                destination.writeText(text)
                listOf(destination.path)
            } else {
                check(multiple || uris.size == 1)
                uris.mapIndexed { index, uri ->
                    check(uri.scheme == "content")
                    val mime = contentResolver.getType(uri) ?: type
                    val rawName = contentResolver.query(
                        uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    }
                    val safeName = rawName.orEmpty()
                        .substringAfterLast('/').substringAfterLast('\\')
                        .filter { it >= ' ' }.trim()
                    val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                        ?: MimeTypeMap.getSingleton().getExtensionFromMimeType(type)
                    val name = if (safeName.substringAfterLast('.', "").isNotEmpty()) {
                        safeName
                    } else {
                        check(!extension.isNullOrEmpty())
                        "Shared file.$extension"
                    }
                    val itemFolder = File(folder, index.toString())
                    check(itemFolder.mkdir())
                    val destination = File(itemFolder, name)
                    val input = checkNotNull(contentResolver.openInputStream(uri))
                    input.use { source ->
                        destination.outputStream().use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val count = source.read(buffer)
                                if (count < 0) break
                                remainingBytes -= count
                                check(remainingBytes >= 0)
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    check(destination.length() > 0)
                    destination.path
                }
            }
        } catch (_: Exception) {
            folder.deleteRecursively()
            emptyList()
        }
        mainHandler.post {
            if (isDestroyed) {
                folder.deleteRecursively()
            } else {
                pendingSharedFiles.add(paths)
                methodChannel?.invokeMethod("onSharedFilesAvailable", null)
            }
        }
    }

    private fun prepareTesseract(dataPath: String, language: String) {
            if (tessApi == null || initializedDataPath != dataPath || initializedLanguage != language) {
                tessApi?.recycle()
                tessApi = TessBaseAPI()
                var ok = try {
                    tessApi!!.init(dataPath, language, TessBaseAPI.OEM_LSTM_ONLY)
                } catch (_: Throwable) {
                    false
                }
                if (!ok) {
                    ok = tessApi!!.init(dataPath, language)
                }
                if (!ok) {
                    tessApi?.recycle()
                    tessApi = null
                    throw IllegalStateException("Could not initialize Tesseract language data: $language")
                }
                initializedDataPath = dataPath
                initializedLanguage = language
            }
    }

    @Synchronized
    private fun runCameraLuma(pixels: ByteArray, width: Int, height: Int,
                              dataPath: String): Pair<String, Double> {
        prepareTesseract(dataPath, "fas+eng")
        val api = tessApi!!
        api.pageSegMode = TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT
        api.setVariable("tessedit_char_whitelist", "")
        api.setVariable("load_system_dawg", "1")
        api.setVariable("load_freq_dawg", "1")
        api.setVariable("thresholding_method", "0")
        api.setVariable("user_defined_dpi", "150")
        return try {
            api.setImage(pixels, width, height, 1, width)
            Pair((api.utF8Text ?: "").trim(),
                (api.meanConfidence() / 100.0).coerceIn(0.0, 1.0))
        } finally {
            api.clear()
        }
    }

    @Synchronized
    private fun runTesseractOcr(
        imagePath: String,
        dataPath: String,
        language: String,
        pageSegMode: Int,
        disableDictionary: Boolean,
        charWhitelist: String,
        adaptiveThreshold: Boolean,
        includeLayout: Boolean
    ): Triple<String, Double, List<Map<String, Any>>> {
        var bitmap: Bitmap? = null
        return try {
            prepareTesseract(dataPath, language)
            tessApi!!.pageSegMode = pageSegMode
            tessApi!!.setVariable("load_system_dawg", if (disableDictionary) "0" else "1")
            tessApi!!.setVariable("load_freq_dawg", if (disableDictionary) "0" else "1")
            tessApi!!.setVariable("user_defined_dpi", "300")
            tessApi!!.setVariable("tessedit_char_whitelist", charWhitelist)
            tessApi!!.setVariable("thresholding_method", if (adaptiveThreshold) "2" else "0")

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(imagePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                throw IllegalArgumentException("The image could not be decoded")
            }
            var sample = 1
            while (bounds.outWidth / sample > 4200 || bounds.outHeight / sample > 4200 ||
                   (bounds.outWidth.toLong() / sample) * (bounds.outHeight / sample) > 12_000_000L) {
                sample *= 2
            }
            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            bitmap = BitmapFactory.decodeFile(imagePath, decodeOptions)
            if (bitmap != null) {
                tessApi!!.setImage(bitmap)
            } else {
                tessApi!!.setImage(File(imagePath))
            }

            var text = (tessApi!!.utF8Text ?: "").trim()
            var confidence = tessApi!!.meanConfidence() / 100.0
            if (text.isEmpty() && pageSegMode == 3) {
                tessApi!!.clear()
                tessApi!!.pageSegMode = TessBaseAPI.PageSegMode.PSM_SINGLE_BLOCK
                if (bitmap != null) {
                    tessApi!!.setImage(bitmap)
                } else {
                    tessApi!!.setImage(File(imagePath))
                }
                text = (tessApi!!.utF8Text ?: "").trim()
                confidence = tessApi!!.meanConfidence() / 100.0
            }
            val lines = if (includeLayout && text.isNotEmpty()) {
                readTextLineBounds(tessApi!!)
            } else emptyList()
            tessApi!!.clear()
            Triple(text, confidence.coerceIn(0.0, 1.0), lines)
        } catch (e: Throwable) {
            throw IllegalStateException("Tesseract OCR failed: ${e.message}", e)
        } finally {
            try {
                bitmap?.recycle()
            } catch (_: Throwable) {}
        }
    }

    private fun readTextLineBounds(api: TessBaseAPI): List<Map<String, Any>> {
        val iterator = api.resultIterator ?: return emptyList()
        val level = TessBaseAPI.PageIteratorLevel.RIL_TEXTLINE
        return try {
            val lines = mutableListOf<Map<String, Any>>()
            iterator.begin()
            do {
                val text = iterator.getUTF8Text(level)?.trim().orEmpty()
                if (text.isEmpty()) continue
                val bounds = iterator.getBoundingRect(level)
                if (bounds.width() > 0 && bounds.height() > 0) {
                    lines.add(mapOf("text" to text,
                        "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                        "confidence" to (iterator.confidence(level) / 100.0).coerceIn(0.0, 1.0)))
                }
            } while (iterator.next(level))
            lines
        } finally {
            iterator.delete()
        }
    }

    private fun runAndroidFaceDetector(imageBytes: ByteArray): List<Map<String, Double>> {
        var decoded: Bitmap? = null
        var rgb565: Bitmap? = null
        return try {
            val opts = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            decoded = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, opts) ?: return emptyList()
            val evenWidth = if (decoded.width % 2 == 0) decoded.width else (decoded.width - 1).coerceAtLeast(2)
            val height = decoded.height.coerceAtLeast(2)
            rgb565 = Bitmap.createBitmap(evenWidth, height, Bitmap.Config.RGB_565)
            val canvas = Canvas(rgb565)
            canvas.drawColor(Color.WHITE)
            canvas.drawBitmap(decoded, 0f, 0f, null)

            val maxFaces = 8
            val detector = FaceDetector(evenWidth, height, maxFaces)
            val faces = arrayOfNulls<FaceDetector.Face>(maxFaces)
            val count = detector.findFaces(rgb565, faces)
            val out = mutableListOf<Map<String, Double>>()
            for (i in 0 until count) {
                val f = faces[i] ?: continue
                if (f.confidence() >= 0.30f) {
                    val mid = PointF()
                    f.getMidPoint(mid)
                    val eyeDist = f.eyesDistance()
                    out.add(
                        mapOf(
                            "x" to (mid.x / evenWidth.toDouble()).coerceIn(0.0, 1.0),
                            "y" to (mid.y / height.toDouble()).coerceIn(0.0, 1.0),
                            "size" to ((eyeDist * 2.4) / evenWidth.toDouble()).coerceIn(0.05, 1.0),
                            "confidence" to f.confidence().toDouble()
                        )
                    )
                }
            }
            out
        } catch (_: Throwable) {
            emptyList()
        } finally {
            try {
                rgb565?.recycle()
                if (decoded != null && decoded != rgb565) decoded.recycle()
            } catch (_: Throwable) {}
        }
    }

    private fun renderPdfPageToPng(pdfPath: String, pageIndex: Int): ByteArray? {
        var fileDescriptor: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        var page: PdfRenderer.Page? = null
        return try {
            val file = File(pdfPath)
            if (!file.exists()) return null
            fileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(fileDescriptor)
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) return null

            page = renderer.openPage(pageIndex)
            // Render enough pixels for small printed text, with a bounded size
            // so large-format PDFs cannot allocate an unbounded bitmap.
            val scale = 3200.0 / maxOf(page.width, page.height).coerceAtLeast(1)
            val width = (page.width * scale).toInt().coerceAtLeast(1)
            val height = (page.height * scale).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Throwable) {
            null
        } finally {
            try {
                page?.close()
                renderer?.close()
                fileDescriptor?.close()
            } catch (_: Throwable) {
            }
        }
    }

    override fun onDestroy() {
        shareExecutor.shutdown()
        cameraPermissionResult?.success("denied")
        cameraPermissionResult = null
        DocumentProcessingService.finishAll()
        try {
            pageFlipPlayer?.release()
            pageFlipPlayer = null
            espeakSynth?.stop()
            // Native OCR may still be using its image and handle. Release on
            // the same executor after its current task, never from the UI thread.
            executor.execute {
                synchronized(this) {
                    tessApi?.recycle()
                    tessApi = null
                }
            }
            executor.shutdown()
            ttsExecutor.shutdown()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }
}
