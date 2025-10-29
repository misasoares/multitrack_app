// Removed file-level Suppress to avoid tooling complaints in some setups
package com.example.multitrack_app

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioDeviceCallback
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.AudioTrack
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*
import kotlin.jvm.Volatile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val EVENT_CHANNEL = "audio_usb/events"
  private val METHOD_CHANNEL = "audio_usb/methods"

    private var eventSink: EventChannel.EventSink? = null
    private lateinit var audioManager: AudioManager
  private var mediaPlayer: MediaPlayer? = null
  private var audioTrack: AudioTrack? = null
  @Volatile private var stopFlag: Boolean = false
  private var previewThread: Thread? = null
  @Volatile private var previewVolume: Float = 1.0f
  @Volatile private var previewPan: Float = 0.0f
  @Volatile private var lastOutputChannel: Int = 0
  @Volatile private var seekRequestSec: Double? = null
  @Volatile private var previewStreams: Array<FileInputStream>? = null
  @Volatile private var usingNative: Boolean = false

    // Estado do mixer Kotlin multifaixa em execução
    private data class KTrackSrc(
        val path: String,
        val channelSel: Int,
        @Volatile var volume: Float,
        @Volatile var pan: Float,
        val channels: Int,
        val sampleRate: Int,
        val bitsPerSample: Int,
        val audioFormat: Int, // 1=PCM, 3=float32
        val dataOffset: Int,
        var ended: Boolean = false
    )
    @Volatile private var currentKotlinTracks: MutableList<KTrackSrc>? = null

    // JNI nativo para suporte multicanal com AAudio
    private external fun nativePlayWavPreview(filePath: String, outputChannel: Int, deviceId: Int, deviceChannels: Int): Boolean
    private external fun nativeStopPreview()
    private external fun nativeSetPreviewVolume(volume: Float)
    private external fun nativeSetPreviewPan(pan: Float)
    private external fun nativePlayAllPreview(
        filePaths: Array<String>,
        outputChannels: IntArray,
        volumes: FloatArray,
        pans: FloatArray,
        deviceId: Int,
        deviceChannels: Int
    ): Boolean
    private external fun nativeSeekAllPreview(positionSec: Double)

    companion object {
        private const val TAG = "MultitrackPreview"
        init {
            try { System.loadLibrary("multichannel_preview") } catch (_: Throwable) {}
        }
    }

    // Utilidades locais para evitar dependência de extensões da stdlib em clamps
    private fun clampFloat(x: Float, min: Float, max: Float): Float {
        return if (x < min) min else if (x > max) max else x
    }
    private fun clampInt(x: Int, min: Int, max: Int): Int {
        return if (x < min) min else if (x > max) max else x
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            if (addedDevices == null) return
            if (addedDevices.any { isUsbAudioOutput(it) }) {
                Log.d(TAG, "USB output device connected")
                eventSink?.success("connected")
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            if (removedDevices == null) return
            if (removedDevices.any { isUsbAudioOutput(it) }) {
                Log.d(TAG, "USB output device disconnected")
                eventSink?.success("disconnected")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine: registering MethodChannel and EventChannel")
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // EventChannel: envia eventos de conexão/desconexão
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        audioManager.registerAudioDeviceCallback(deviceCallback, null)
                    }
                    // Estado inicial
                    val hasUsb = getUsbOutputDevice() != null
                    Log.d(TAG, "EventChannel onListen; initial usbConnected=$hasUsb")
                    events?.success(if (hasUsb) "connected" else "disconnected")
                }

                override fun onCancel(arguments: Any?) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        audioManager.unregisterAudioDeviceCallback(deviceCallback)
                    }
                    eventSink = null
                }
            })

        // MethodChannel: retorna detalhes dos canais do dispositivo USB conectado
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "seekPlayAll" -> {
                        val args = call.arguments as? Map<*, *>
                        val posSec = (args?.get("positionSec") as? Number)?.toDouble() ?: 0.0
                        val tgt = if (posSec.isNaN() || posSec < 0.0) 0.0 else posSec
                        if (usingNative) {
                            try { nativeSeekAllPreview(tgt) } catch (_: Throwable) {}
                        } else {
                            seekRequestSec = tgt
                        }
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    "playAllPreview" -> {
                        val args = call.arguments as? Map<*, *>
                        val filePathsList = (args?.get("filePaths") as? List<*>)?.mapNotNull { it as? String } ?: listOf<String>()
                        val outputChannelsList = (args?.get("outputChannels") as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: listOf<Int>()
                        val volumesList = (args?.get("volumes") as? List<*>)?.mapNotNull { (it as? Number)?.toFloat() } ?: listOf<Float>()
                        val pansList = (args?.get("pans") as? List<*>)?.mapNotNull { (it as? Number)?.toFloat() } ?: listOf<Float>()
                        if (filePathsList.isEmpty() ||
                            outputChannelsList.size != filePathsList.size ||
                            volumesList.size != filePathsList.size ||
                            pansList.size != filePathsList.size) {
                            result.error("bad_args", "Listas inválidas para playAllPreview", null)
                            return@setMethodCallHandler
                        }

                        // Limpa players anteriores
                        try { nativeStopPreview() } catch (_: Throwable) {}
                        stopFlag = true
                        try { previewThread?.join(500) } catch (_: Throwable) {}
                        previewThread = null
                        audioTrack?.stop(); audioTrack?.release(); audioTrack = null
                        mediaPlayer?.stop(); mediaPlayer?.release(); mediaPlayer = null
                        usingNative = false

                        try {
                            // Preferir caminho nativo AAudio
                            val usb = getUsbOutputDevice()
                            val deviceId = usb?.id ?: -1
                            val deviceCh = try { if (usb != null) computeOutputChannelCount(usb) else 2 } catch (_: Throwable) { 2 }
                            // Constrói arrays sem extensões para compatibilidade
                            val fpArr = Array(filePathsList.size) { "" }
                            for (i in filePathsList.indices) fpArr[i] = filePathsList[i]
                            val chArr = IntArray(outputChannelsList.size)
                            for (i in outputChannelsList.indices) chArr[i] = outputChannelsList[i]
                            val volArr = FloatArray(volumesList.size)
                            for (i in volumesList.indices) volArr[i] = clampFloat(volumesList[i], 0f, 1f)
                            val panArr = FloatArray(pansList.size)
                            for (i in pansList.indices) panArr[i] = clampFloat(pansList[i], -1f, 1f)
                            val ok = nativePlayAllPreview(
                                fpArr,
                                chArr,
                                volArr,
                                panArr,
                                deviceId,
                                deviceCh
                            )
                            if (ok) {
                                usingNative = true
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            // Fallback: mixer em Kotlin/AudioTrack estéreo
                            val ok2 = playAllWavPreviewKotlin(filePathsList, outputChannelsList, volumesList, pansList)
                            if (!ok2) {
                                result.error("play_error", "Falha ao iniciar mixer", null)
                            } else {
                                usingNative = false
                                result.success(null)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "playAllPreview error: ${e.message}", e)
                            result.error("play_error", e.message, null)
                        }
                    }
                    "getOutputChannelDetails" -> {
                        val device = getUsbOutputDevice()
                        if (device == null) {
                            val resp = HashMap<String, Any>()
                            resp["deviceName"] = ""
                            resp["outputChannelCount"] = 0
                            resp["outputChannels"] = ArrayList<String>()
                            result.success(resp)
                        } else {
                            val name = device.productName?.toString() ?: "Dispositivo USB"
                            val count = computeOutputChannelCount(device)
                            Log.d(TAG, "USB output details: name=${name}, channelCount=${count}")
                            val list = ArrayList<String>()
                            var i = 1
                            while (i <= count) { list.add("Canal de Saída $i"); i++ }
                            val resp = HashMap<String, Any>()
                            resp["deviceName"] = name
                            resp["outputChannelCount"] = count
                            resp["outputChannels"] = list
                            result.success(resp)
                        }
                    }
                    "getInputChannelDetails" -> {
                        val device = getUsbInputDevice()
                        if (device == null) {
                            val resp = HashMap<String, Any>()
                            resp["deviceName"] = ""
                            resp["inputChannelCount"] = 0
                            resp["inputChannels"] = ArrayList<String>()
                            result.success(resp)
                        } else {
                            val name = device.productName?.toString() ?: "Dispositivo USB"
                            val count = computeInputChannelCount(device)
                            val list = ArrayList<String>()
                            var i = 1
                            while (i <= count) { list.add("Canal de Entrada $i"); i++ }
                            val resp = HashMap<String, Any>()
                            resp["deviceName"] = name
                            resp["inputChannelCount"] = count
                            resp["inputChannels"] = list
                            result.success(resp)
                        }
                    }
                    "playPreview" -> {
                        val args = call.arguments as? Map<*, *>
                        val filePath = args?.get("filePath") as? String
                        val outputChannel = (args?.get("outputChannel") as? Int) ?: 0
                        lastOutputChannel = outputChannel

                        try {
                            Log.d(TAG, "playPreview: filePath=${filePath}, outputChannel=${outputChannel}")
                            // Parar/release se já existe um player
                            mediaPlayer?.stop()
                            mediaPlayer?.release()
                            mediaPlayer = null
                            stopFlag = true
                            try { previewThread?.join(500) } catch (_: Throwable) {}
                            previewThread = null
                            audioTrack?.stop()
                            audioTrack?.release()
                            audioTrack = null
                            Log.d(TAG, "playPreview: previous players cleared")

                            if (filePath.isNullOrEmpty()) {
                                Log.e(TAG, "playPreview: filePath ausente")
                                result.error("bad_args", "filePath ausente", null)
                                return@setMethodCallHandler
                            }

                            val isWav = filePath.lowercase().endsWith(".wav")
                            Log.d(TAG, "playPreview: isWav=${isWav}")
                            // Tenta caminho nativo multicanal para WAV quando dispositivo USB possui 3+ canais ou canal selecionado >=2
                            if (isWav && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val usb = getUsbOutputDevice()
                                val deviceId = usb?.id ?: -1
                                val deviceCh = try { if (usb != null) computeOutputChannelCount(usb) else 2 } catch (_: Throwable) { 2 }
                                Log.d(TAG, "playPreview: USB deviceId=${deviceId}, name=${usb?.productName}, computedChannels=${deviceCh}")
                                if (deviceCh >= 3 || outputChannel >= 2) {
                                    Log.d(TAG, "playPreview: trying native AAudio path for WAV; outputChannel=${outputChannel}")
                                    val ok = nativePlayWavPreview(filePath, outputChannel, deviceId, deviceCh)
                                    Log.d(TAG, "playPreview: nativePlayWavPreview returned ok=${ok}")
                                    if (ok) {
                                        try { nativeSetPreviewVolume(previewVolume) } catch (_: Throwable) {}
                                        try { nativeSetPreviewPan(previewPan) } catch (_: Throwable) {}
                                        Log.d(TAG, "playPreview: using native AAudio for WAV")
                                        result.success(null)
                                        return@setMethodCallHandler
                                    }
                                    // se falhar, continua no fallback abaixo
                                    Log.w(TAG, "playPreview: native AAudio failed; falling back to Kotlin path")
                                }
                            }
                    if (isWav) {
                        // Tocar via AudioTrack (WAV PCM) com roteamento estéreo simples
                        Log.d(TAG, "playPreview: using AudioTrack stereo path for WAV")
                        val ok2 = playWavPreview(filePath, outputChannel)
                        if (ok2) {
                            // Aplica volume inicial
                            try { audioTrack?.setVolume(previewVolume) } catch (_: Throwable) {}
                            // Aplica pan inicial (no caminho AudioTrack será aplicado por amostra)
                            result.success(null)
                        } else {
                            Log.w(TAG, "playPreview: WAV unsupported or failed in AudioTrack path; falling back to MediaPlayer")
                            playWithMediaPlayer(filePath, outputChannel)
                            // Aplica volume inicial
                            applyMediaPlayerVolumeForChannel(previewVolume, outputChannel)
                            result.success(null)
                        }
                    } else {
                        // Fallback: MediaPlayer com L/R simples
                        Log.d(TAG, "playPreview: using MediaPlayer fallback (non-WAV)")
                        playWithMediaPlayer(filePath, outputChannel)
                        applyMediaPlayerVolumeForChannel(previewVolume, outputChannel)
                        result.success(null)
                    }
                        } catch (e: Exception) {
                            Log.e(TAG, "playPreview error: ${e.message}", e)
                            result.error("play_error", e.message, null)
                        }
                    }
                    "stopPreview" -> {
                        try {
                            Log.d(TAG, "stopPreview invoked")
                            try { nativeStopPreview() } catch (_: Throwable) {}
                            stopFlag = true
                            try { previewThread?.join(500) } catch (_: Throwable) {}
                            previewThread = null
                            audioTrack?.stop()
                            audioTrack?.release()
                            audioTrack = null
                            mediaPlayer?.stop()
                            mediaPlayer?.release()
                            mediaPlayer = null
                            usingNative = false
                            Log.d(TAG, "stopPreview: players stopped and released")
                        } catch (_: Throwable) {
                            Log.e(TAG, "stopPreview error")
                        }
                        result.success(null)
                    }
                    "setPreviewVolume" -> {
                        val args = call.arguments as? Map<*, *>
                        val vol = ((args?.get("volume") as? Number)?.toFloat()) ?: 1.0f
                        val clamped = vol.coerceIn(0.0f, 1.0f)
                        // Quando o mixer Kotlin multifaixa está ativo, evitar alterar o volume global
                        // para não afetar todas as tracks. Utilize "setTrackVolume" no Flutter.
                        val tracks = currentKotlinTracks
                        if (tracks != null) {
                            // Compat: se vier "trackIndex" nos args, trate como setTrackVolume
                            val idx = ((args?.get("trackIndex") as? Number)?.toInt())
                            if (idx != null && idx in tracks.indices) {
                                tracks[idx].volume = clamped
                                Log.d(TAG, "setPreviewVolume aplicado como setTrackVolume: trackIndex=${idx} volume=${clamped}")
                                result.success(null)
                            } else {
                                Log.d(TAG, "setPreviewVolume ignorado: mixer multifaixa ativo; use setTrackVolume")
                                result.success(null)
                            }
                        } else {
                            previewVolume = clamped
                            try { nativeSetPreviewVolume(previewVolume) } catch (_: Throwable) {}
                            try { audioTrack?.setVolume(previewVolume) } catch (_: Throwable) {}
                            applyMediaPlayerVolumeForChannel(previewVolume, lastOutputChannel)
                            result.success(null)
                        }
                    }
                    "setPreviewPan" -> {
                        val args = call.arguments as? Map<*, *>
                        val pan = ((args?.get("pan") as? Number)?.toFloat()) ?: 0.0f
                        val clamped = pan.coerceIn(-1.0f, 1.0f)
                        val tracks = currentKotlinTracks
                        if (tracks != null) {
                            // Compat: se vier "trackIndex" nos args, trate como setTrackPan
                            val idx = ((args?.get("trackIndex") as? Number)?.toInt())
                            if (idx != null && idx in tracks.indices) {
                                tracks[idx].pan = clamped
                                Log.d(TAG, "setPreviewPan aplicado como setTrackPan: trackIndex=${idx} pan=${clamped}")
                                result.success(null)
                            } else {
                                Log.d(TAG, "setPreviewPan ignorado: mixer multifaixa ativo; use setTrackPan")
                                result.success(null)
                            }
                        } else {
                            previewPan = clamped
                            try { nativeSetPreviewPan(previewPan) } catch (_: Throwable) {}
                            // MediaPlayer: aplicar imediatamente
                            applyMediaPlayerVolumeForChannel(previewVolume, lastOutputChannel)
                            result.success(null)
                        }
                    }
                    "setTrackPan" -> {
                        val args = call.arguments as? Map<*, *>
                        val index = ((args?.get("trackIndex") as? Number)?.toInt()) ?: -1
                        val pan = ((args?.get("pan") as? Number)?.toFloat()) ?: 0.0f
                        val clamped = pan.coerceIn(-1.0f, 1.0f)
                        val tracks = currentKotlinTracks
                        if (tracks != null && index in tracks.indices) {
                            tracks[index].pan = clamped
                            Log.d(TAG, "setTrackPan: trackIndex=${index} pan=${clamped}")
                            result.success(null)
                        } else {
                            // Fallback: aplica pan global quando não há mixer Kotlin ativo
                            previewPan = clamped
                            try { nativeSetPreviewPan(previewPan) } catch (_: Throwable) {}
                            applyMediaPlayerVolumeForChannel(previewVolume, lastOutputChannel)
                            result.success(null)
                        }
                    }
                    "setTrackVolume" -> {
                        val args = call.arguments as? Map<*, *>
                        val index = ((args?.get("trackIndex") as? Number)?.toInt()) ?: -1
                        val vol = ((args?.get("volume") as? Number)?.toFloat()) ?: 1.0f
                        val clamped = vol.coerceIn(0.0f, 1.0f)
                        val tracks = currentKotlinTracks
                        if (tracks != null && index in tracks.indices) {
                            tracks[index].volume = clamped
                            Log.d(TAG, "setTrackVolume: trackIndex=${index} volume=${clamped}")
                            result.success(null)
                        } else {
                            // Fallback: aplica volume global quando não há mixer Kotlin ativo
                            previewVolume = clamped
                            try { nativeSetPreviewVolume(previewVolume) } catch (_: Throwable) {}
                            try { audioTrack?.setVolume(previewVolume) } catch (_: Throwable) {}
                            applyMediaPlayerVolumeForChannel(previewVolume, lastOutputChannel)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun playWavPreview(filePath: String, outputChannel: Int): Boolean {
        try {
            val file = File(filePath)
            val fis = FileInputStream(file)

            // Parse cabeçalho WAV simples (RIFF PCM 16-bit LE)
            val header = ByteArray(44)
            val read = fis.read(header)
            if (read < 44) {
                Log.e(TAG, "playWavPreview: header read too small: ${read}")
                fis.close(); return false
            }
            val bb = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val riff = String(header, 0, 4)
            val wave = String(header, 8, 4)
            if (riff != "RIFF" || wave != "WAVE") {
                Log.e(TAG, "playWavPreview: not a RIFF/WAVE file")
                fis.close(); return false
            }
            // fmt chunk at 12..35 usual
            val audioFormat = bb.getShort(20).toInt() // 1 = PCM
            val channels = bb.getShort(22).toInt()
            val sampleRate = bb.getInt(24)
            val bitsPerSample = bb.getShort(34).toInt()
            if (audioFormat != 1 || bitsPerSample != 16) {
                Log.e(TAG, "playWavPreview: unsupported format=${audioFormat} bits=${bitsPerSample}")
                fis.close(); return false
            }

            // Data chunk may not start at 36; find 'data' marker
            var dataOffset = 36
            var dataSize = 0
            run {
                var pos = 12
                while (pos + 8 <= header.size) {
                    val chunkId = String(header, pos, 4)
                    val chunkSize = bb.getInt(pos + 4)
                    if (chunkId == "data") {
                        dataOffset = pos + 8
                        dataSize = chunkSize
                        break
                    }
                    pos += 8 + chunkSize
                }
            }
            // Se 'data' não estiver no cabeçalho, teremos que fazer fallback simples
            if (dataSize <= 0) {
                Log.e(TAG, "playWavPreview: data chunk not found or size<=0")
                fis.close(); return false
            }
            Log.d(TAG, "playWavPreview: WAV fmt: channels=${channels}, sampleRate=${sampleRate}, bits=${bitsPerSample}, dataOffset=${dataOffset}, dataSize=${dataSize}")

            // Configurar AudioTrack estéreo para roteamento L/R
            val channelOut = if (channels >= 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_STEREO
            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate,
                channelOut,
                AudioFormat.ENCODING_PCM_16BIT
            )
            val track = AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelOut)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
                minBuf,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE
            )
            Log.d(TAG, "playWavPreview: AudioTrack created minBuf=${minBuf}, channelMask=${channelOut}")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                getUsbOutputDevice()?.let {
                    try { track.preferredDevice = it } catch (_: Throwable) {}
                    Log.d(TAG, "playWavPreview: preferredDevice set: id=${it.id}, name=${it.productName}")
                }
            }

            stopFlag = false
            track.play()
            audioTrack = track
            Log.d(TAG, "playWavPreview: track.play() called; streaming thread starting, outputChannel=${outputChannel}")

            // Preparar leitura de dados PCM e roteamento
            // Vamos reler o arquivo desde dataOffset
            fis.close()
            val stream = FileInputStream(file)
            // Skip até dataOffset
            stream.skip(dataOffset.toLong())

            previewThread = Thread {
                val buf = ByteArray(4096)
                val sampleBuf = ShortArray(buf.size / 2)
                var readsLogged = 0
                try {
                    while (!stopFlag) {
                        val n = stream.read(buf)
                        if (n <= 0) break
                        // bytes -> short LE
                        val shorts = n / 2
                        ByteBuffer.wrap(buf, 0, n).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(sampleBuf, 0, shorts)

                        if (channels >= 2) {
                            // Interleaved Stereo: L, R
                            // Roteia zerando o canal oposto
                            var i = 0
                            while (i + 1 < shorts) {
                                val left = sampleBuf[i]
                                val right = sampleBuf[i + 1]
                                when (outputChannel) {
                                    0 -> { // Left only
                                        sampleBuf[i] = left
                                        sampleBuf[i + 1] = 0
                                    }
                                    1 -> { // Right only
                                        sampleBuf[i] = 0
                                        sampleBuf[i + 1] = right
                                    }
                                    else -> {
                                        // Both
                                        sampleBuf[i] = left
                                        sampleBuf[i + 1] = right
                                    }
                                }
                                i += 2
                            }
                        } else {
                            // Mono: duplica para estéreo e aplica roteamento
                            // expand buffer to stereo
                            val stereo = ShortArray(shorts * 2)
                            var j = 0
                            val pan = previewPan.coerceIn(-1.0f, 1.0f)
                            // Equal-power pan para mono expandido
                            val t = (pan + 1.0f) / 2.0f
                            val angle = (PI / 2.0) * t
                            val leftGain = cos(angle).toFloat()
                            val rightGain = sin(angle).toFloat()
                            while (j < shorts) {
                                val s = sampleBuf[j]
                                when (outputChannel) {
                                    0 -> { stereo[2*j] = s; stereo[2*j+1] = 0 }
                                    1 -> { stereo[2*j] = 0; stereo[2*j+1] = s }
                                    else -> {
                                        val ls = (s * leftGain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                                        val rs = (s * rightGain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                                        stereo[2*j] = ls
                                        stereo[2*j+1] = rs
                                    }
                                }
                                j++
                            }
                            track.write(stereo, 0, stereo.size)
                            if (readsLogged < 3) { Log.d(TAG, "playWavPreview: wrote mono->stereo chunk size=${stereo.size}"); readsLogged++ }
                            continue
                        }
                        // Se arquivo estéreo, isolar L/R quando solicitado
                        if (outputChannel == 0) {
                            var j = 0
                            while (j + 1 < shorts) {
                                // zera R, mantém L
                                sampleBuf[j + 1] = 0
                                j += 2
                            }
                        } else if (outputChannel == 1) {
                            var j = 0
                            while (j + 1 < shorts) {
                                // zera L, mantém R
                                sampleBuf[j] = 0
                                j += 2
                            }
                        } // else: par (>=2) mantém estéreo intacto

                        // Aplicar pan em estéreo quando par (>=2)
                        if (outputChannel >= 2) {
                            val pan = previewPan.coerceIn(-1.0f, 1.0f)
                            // Equal-power pan para estéreo
                            val t = (pan + 1.0f) / 2.0f
                            val angle = (PI / 2.0) * t
                            val leftGain = cos(angle).toFloat()
                            val rightGain = sin(angle).toFloat()
                            var k = 0
                            while (k + 1 < shorts) {
                                val l = (sampleBuf[k] * leftGain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                                val r = (sampleBuf[k + 1] * rightGain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                                sampleBuf[k] = l
                                sampleBuf[k + 1] = r
                                k += 2
                            }
                        }

                        track.write(sampleBuf, 0, shorts)
                        if (readsLogged < 3) { Log.d(TAG, "playWavPreview: wrote stereo chunk shorts=${shorts} outputChannel=${outputChannel}"); readsLogged++ }
                    }
                } catch (_: Throwable) {
                    Log.e(TAG, "playWavPreview: streaming error")
                } finally {
                    try { stream.close() } catch (_: Throwable) {}
                    try {
                        track.stop(); track.release()
                    } catch (_: Throwable) {}
                    if (audioTrack === track) audioTrack = null
                    Log.d(TAG, "playWavPreview: streaming finished; track released")
                }
            }
            previewThread?.start()
            return true
        } catch (_: Throwable) {
            Log.e(TAG, "playWavPreview: error creating track/reading file")
            return false
        }
    }

    private fun playWithMediaPlayer(filePath: String, outputChannel: Int) {
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
        )
        mp.setDataSource(filePath)

        // Preferir saída USB se disponível (Android 9+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val usb = getUsbOutputDevice()
            if (usb != null) {
                try {
                    mp.setPreferredDevice(usb)
                    Log.d(TAG, "MediaPlayer preferredDevice set: id=${usb.id}, name=${usb.productName}")
                } catch (_: Throwable) { /* ignora */ }
                // Se dispositivo for ao menos estéreo, faça roteamento simples L/R
                try {
                    val count = computeOutputChannelCount(usb)
                    if (count >= 2) {
                        when (outputChannel) {
                            0 -> { mp.setVolume(1.0f, 0.0f); Log.d(TAG, "MediaPlayer volume L=1 R=0 (Left)") }
                            1 -> { mp.setVolume(0.0f, 1.0f); Log.d(TAG, "MediaPlayer volume L=0 R=1 (Right)") }
                            else -> { mp.setVolume(1.0f, 1.0f); Log.d(TAG, "MediaPlayer volume L=1 R=1 (Both)") }
                        }
                    }
                } catch (_: Throwable) { /* ignora */ }
            }
        }

        mp.setOnPreparedListener { p ->
            Log.d(TAG, "MediaPlayer prepared; starting playback")
            p.start()
        }
        mp.setOnCompletionListener {
            try {
                it.release()
            } catch (_: Throwable) {}
            if (mediaPlayer === it) mediaPlayer = null
            Log.d(TAG, "MediaPlayer completion; released")
        }
        mp.setOnErrorListener { player, _, _ ->
            try {
                player.release()
            } catch (_: Throwable) {}
            if (mediaPlayer === player) mediaPlayer = null
            Log.e(TAG, "MediaPlayer error; released")
            false
        }

        mp.prepareAsync()
        mediaPlayer = mp
    }

    private fun applyMediaPlayerVolumeForChannel(volume: Float, outputChannel: Int) {
        val mp = mediaPlayer ?: return
        val vol = volume.coerceIn(0.0f, 1.0f)
        val pan = previewPan.coerceIn(-1.0f, 1.0f)
        // Equal-power pan: mantém potência constante no centro
        val t = (pan + 1.0f) / 2.0f
        val angle = (PI / 2.0) * t
        val leftGain = cos(angle).toFloat()
        val rightGain = sin(angle).toFloat()
        val (l, r) = when (outputChannel) {
            0 -> vol to 0.0f
            1 -> 0.0f to vol
            else -> (vol * leftGain) to (vol * rightGain)
        }
        try { mp.setVolume(l, r) } catch (_: Throwable) {}
        Log.d(TAG, "MediaPlayer setVolume L=${l} R=${r}")
    }

    private fun isUsbAudioOutput(info: AudioDeviceInfo): Boolean {
        return info.isSink && (info.type == AudioDeviceInfo.TYPE_USB_DEVICE || info.type == AudioDeviceInfo.TYPE_USB_HEADSET)
    }

    private fun getUsbOutputDevice(): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val dev = outputs.firstOrNull { isUsbAudioOutput(it) }
        Log.d(TAG, "getUsbOutputDevice: found=${dev != null} name=${dev?.productName} id=${dev?.id}")
        return dev
    }

    private fun isUsbAudioInput(info: AudioDeviceInfo): Boolean {
        return info.isSource && (info.type == AudioDeviceInfo.TYPE_USB_DEVICE || info.type == AudioDeviceInfo.TYPE_USB_HEADSET)
    }

    private fun getUsbInputDevice(): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val inputs = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return inputs.firstOrNull { isUsbAudioInput(it) }
    }

    private fun computeOutputChannelCount(device: AudioDeviceInfo): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return 2
        val counts = device.channelCounts
        if (counts != null && counts.isNotEmpty()) {
            val ret = counts.maxOrNull() ?: counts.first()
            Log.d(TAG, "computeOutputChannelCount via counts: counts=${counts.contentToString()} ret=${ret}")
            return ret
        }
        val masks = device.channelMasks
        if (masks != null && masks.isNotEmpty()) {
            // Mapeamento básico de máscaras para número de canais
            val mapped = masks.map { mask ->
                when (mask) {
                    AudioFormat.CHANNEL_OUT_MONO -> 1
                    AudioFormat.CHANNEL_OUT_STEREO -> 2
                    AudioFormat.CHANNEL_OUT_5POINT1 -> 6
                    AudioFormat.CHANNEL_OUT_7POINT1 -> 8
                    AudioFormat.CHANNEL_OUT_SURROUND -> 4
                    else -> 2 // fallback
                }
            }
            val ret = mapped.maxOrNull() ?: 2
            Log.d(TAG, "computeOutputChannelCount via masks: masks=${masks.contentToString()} mapped=${mapped} ret=${ret}")
            return ret
        }
        // Fallback padrão se API não reportar
        return 2
    }

    private fun computeInputChannelCount(device: AudioDeviceInfo): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return 2
        val counts = device.channelCounts
        if (counts != null && counts.isNotEmpty()) {
            return counts.maxOrNull() ?: counts.first()
        }
        val masks = device.channelMasks
        if (masks != null && masks.isNotEmpty()) {
            // Mapeamento básico de máscaras para número de canais de entrada
            return masks.map { mask ->
                when (mask) {
                    AudioFormat.CHANNEL_IN_MONO -> 1
                    AudioFormat.CHANNEL_IN_STEREO -> 2
                    AudioFormat.CHANNEL_IN_FRONT -> 2
                    else -> 2 // fallback
                }
            }.maxOrNull() ?: 2
        }
        // Fallback padrão
        return 2
    }
    
    private fun playAllWavPreviewKotlin(
        filePaths: List<String>,
        outputChannels: List<Int>,
        volumes: List<Float>,
        pans: List<Float>
    ): Boolean {
        try {
            // Abrir e validar WAVs
            data class Header(
                val channels: Int,
                val sampleRate: Int,
                val bitsPerSample: Int,
                val audioFormat: Int,
                val dataOffset: Int,
                val dataSize: Int
            )
            fun parseHeader(fis: FileInputStream): Header? {
                // Parse robusto: lê RIFF/WAVE, depois itera chunks até achar fmt e data
                val riffHead = ByteArray(12)
                val n0 = fis.read(riffHead)
                if (n0 < 12) return null
                val riffId = String(riffHead, 0, 4)
                val waveId = String(riffHead, 8, 4)
                if (riffId != "RIFF" || waveId != "WAVE") return null
                var audioFormat = -1
                var ch = 0
                var sr = 0
                var bps = 0
                var dataOffset = -1
                var dataSize = -1
                var pos = 12
                val hdr8 = ByteArray(8)
                while (true) {
                    val n = fis.read(hdr8)
                    if (n < 8) break
                    val id = String(hdr8, 0, 4)
                    val size = ByteBuffer.wrap(hdr8, 4, 4).order(ByteOrder.LITTLE_ENDIAN).getInt()
                    pos += 8
                    if (id == "fmt ") {
                        val fmtBuf = ByteArray(size)
                        val m = fis.read(fmtBuf)
                        if (m < size) return null
                        val bb = ByteBuffer.wrap(fmtBuf).order(ByteOrder.LITTLE_ENDIAN)
                        audioFormat = bb.getShort(0).toInt() and 0xFFFF
                        ch = bb.getShort(2).toInt() and 0xFFFF
                        sr = bb.getInt(4)
                        bps = if (size >= 16) bb.getShort(14).toInt() and 0xFFFF else 0
                        pos += size
                    } else if (id == "data") {
                        dataOffset = pos
                        dataSize = size
                        // não consome payload aqui; thread fará o skip
                        break
                    } else {
                        // pular chunks desconhecidos
                        val skipped = fis.skip(size.toLong())
                        pos += size
                    }
                }
                val supported = (audioFormat == 1 && (bps == 16 || bps == 24)) || (audioFormat == 3 && bps == 32)
                if (!supported) return null
                if (dataOffset < 0) return null
                if (dataSize <= 0) return null
                return Header(ch, sr, bps, audioFormat, dataOffset, dataSize)
            }

            val srcs = mutableListOf<KTrackSrc>()
            for (i in filePaths.indices) {
                val fp = filePaths[i]
                val fis = FileInputStream(File(fp))
                val parsed = parseHeader(fis)
                try { fis.close() } catch (_: Throwable) {}
                if (parsed == null) {
                    return false
                }
                val ch = parsed.channels
                val sr = parsed.sampleRate
                val bps = parsed.bitsPerSample
                val fmt = parsed.audioFormat
                val off = parsed.dataOffset
                srcs.add(
                    KTrackSrc(
                        path = fp,
                        channelSel = outputChannels[i],
                        volume = volumes[i].coerceIn(0f, 1f),
                        pan = pans[i].coerceIn(-1f, 1f),
                        channels = ch,
                        sampleRate = sr,
                        bitsPerSample = bps,
                        audioFormat = fmt,
                        dataOffset = off
                    )
                )
            }
            currentKotlinTracks = srcs
            // Verifica sampleRate consistente
            val baseSr = srcs.firstOrNull()?.sampleRate ?: return false
            if (srcs.any { it.sampleRate != baseSr }) {
                Log.e(TAG, "playAllWavPreviewKotlin: sample rates mismatch")
                return false
            }

            // AudioTrack estéreo
            val channelOut = AudioFormat.CHANNEL_OUT_STEREO
            val minBuf = AudioTrack.getMinBufferSize(baseSr, channelOut, AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(baseSr)
                    .setChannelMask(channelOut)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build(),
                minBuf,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                getUsbOutputDevice()?.let { try { track.preferredDevice = it } catch (_: Throwable) {} }
            }
            stopFlag = false
            audioTrack = track
            track.play()

            previewThread = Thread {
                var streams: Array<FileInputStream>? = null
                try {
                    // abrir streams por faixa e posicionar em dataOffset
                    streams = Array(srcs.size) { i -> FileInputStream(File(srcs[i].path)) }
                    for (i in srcs.indices) {
                        try { streams[i].skip(srcs[i].dataOffset.toLong()) } catch (_: Throwable) {}
                    }
                    // torna streams acessíveis para seek
                    previewStreams = streams
                    val BYTES = 4096
                    val tmpBytes = Array(srcs.size) { ByteArray(BYTES) }
                    val tmpShorts = Array(srcs.size) { ShortArray(BYTES / 2) }
                    while (!stopFlag) {
                        // Aplica pedido de seek, se houver
                        seekRequestSec?.let { targetSec ->
                            seekRequestSec = null
                            try {
                                for (i in srcs.indices) {
                                    val s = srcs[i]
                                    val ch = streams ?: break
                                    val bytesPerSample = if (s.bitsPerSample == 24) 3 else (s.bitsPerSample / 8)
                                    val bytesPerFrame = bytesPerSample * s.channels
                                    val targetFrames = (targetSec * s.sampleRate).toLong()
                                    val offsetBytes = s.dataOffset.toLong() + targetFrames * bytesPerFrame
                                    try {
                                        ch[i].channel.position(offsetBytes)
                                        s.ended = false
                                    } catch (_: Throwable) {
                                        s.ended = true
                                    }
                                }
                                // Tenta limpar buffer e retomar
                                try {
                                    track.pause()
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                        // flush existe em algumas versões; engole erros
                                        try { track.flush() } catch (_: Throwable) {}
                                    }
                                    track.play()
                                } catch (_: Throwable) {}
                            } catch (e: Exception) {
                                Log.e(TAG, "seekPlayAll apply error: ${e.message}", e)
                            }
                        }
                        // lê de todos
                        var anyData = false
                        val framesPerSrc = IntArray(srcs.size)
                        for (i in srcs.indices) {
                            val s = srcs[i]
                            if (s.ended) { framesPerSrc[i] = 0; continue }
                            val sArr = streams ?: break
                            val n = sArr[i].read(tmpBytes[i])
                            if (n <= 0) { s.ended = true; framesPerSrc[i] = 0; continue }
                            anyData = true
                            when {
                                s.audioFormat == 1 && s.bitsPerSample == 16 -> {
                                    val samples = n / 2
                                    ByteBuffer.wrap(tmpBytes[i], 0, n).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(tmpShorts[i], 0, samples)
                                    framesPerSrc[i] = samples / s.channels
                                }
                                s.audioFormat == 1 && s.bitsPerSample == 24 -> {
                                    val samples = n / 3
                                    var idxBytes = 0
                                    for (k in 0 until samples) {
                                        val b0 = tmpBytes[i][idxBytes].toInt() and 0xFF
                                        val b1 = tmpBytes[i][idxBytes + 1].toInt() and 0xFF
                                        val b2 = tmpBytes[i][idxBytes + 2].toInt() and 0xFF
                                        var v = (b2 shl 16) or (b1 shl 8) or b0
                                        if ((v and 0x800000) != 0) {
                                            v = v or -0x1000000 // sign extend to 32-bit
                                        }
                                        // Convert 24-bit to 16-bit by shifting
                                        tmpShorts[i][k] = (v shr 8).toShort()
                                        idxBytes += 3
                                    }
                                    framesPerSrc[i] = samples / s.channels
                                }
                                s.audioFormat == 3 && s.bitsPerSample == 32 -> {
                                    val floats = n / 4
                                    val floatArr = FloatArray(floats)
                                    ByteBuffer.wrap(tmpBytes[i], 0, n).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floatArr, 0, floats)
                                    for (k in 0 until floats) {
                                        val f = floatArr[k].coerceIn(-1f, 1f)
                                        val v = (f * 32767f).toInt()
                                        val clamped = when {
                                            v > Short.MAX_VALUE.toInt() -> Short.MAX_VALUE.toInt()
                                            v < Short.MIN_VALUE.toInt() -> Short.MIN_VALUE.toInt()
                                            else -> v
                                        }
                                        tmpShorts[i][k] = clamped.toShort()
                                    }
                                    framesPerSrc[i] = floats / s.channels
                                }
                                else -> {
                                    // Unsupported format in fallback; mark ended
                                    framesPerSrc[i] = 0
                                    srcs[i].ended = true
                                }
                            }
                        }
                        if (!anyData) break
                        // define frames de saída como o mínimo disponível
                        val frames = framesPerSrc.filter { it > 0 }.minOrNull() ?: 0
                        if (frames <= 0) continue
                        // acumula estéreo em int
                        val accL = IntArray(frames)
                        val accR = IntArray(frames)
                        for (i in srcs.indices) {
                            val s = srcs[i]
                            val pan = s.pan.coerceIn(-1f, 1f)
                            val t = (pan + 1f) / 2f
                            val angle = (PI / 2.0) * t
                            val leftGain = cos(angle).toFloat()
                            val rightGain = sin(angle).toFloat()
                            val vol = s.volume.coerceIn(0f, 1f)
                            if (framesPerSrc[i] <= 0) continue
                            if (s.channels >= 2) {
                                var f = 0
                                var idx = 0
                                while (f < frames) {
                                    val l = tmpShorts[i][idx]
                                    val r = tmpShorts[i][idx + 1]
                                    val (outL, outR) = when {
                                        s.channelSel == 0 -> Pair((l * vol).toInt(), 0)
                                        s.channelSel == 1 -> Pair(0, (r * vol).toInt())
                                        else -> Pair((l * leftGain * vol).toInt(), (r * rightGain * vol).toInt())
                                    }
                                    accL[f] += outL
                                    accR[f] += outR
                                    f += 1
                                    idx += 2
                                }
                            } else {
                                var f = 0
                                var idx = 0
                                while (f < frames) {
                                    val m = tmpShorts[i][idx]
                                    val (outL, outR) = when {
                                        s.channelSel == 0 -> Pair((m * vol).toInt(), 0)
                                        s.channelSel == 1 -> Pair(0, (m * vol).toInt())
                                        else -> Pair((m * leftGain * vol).toInt(), (m * rightGain * vol).toInt())
                                    }
                                    accL[f] += outL
                                    accR[f] += outR
                                    f += 1
                                    idx += 1
                                }
                            }
                        }
                        // clamp e interleave
                        val out = ShortArray(frames * 2)
                        var p = 0
                        for (f in 0 until frames) {
                            var l = accL[f]
                            var r = accR[f]
                            if (l > Short.MAX_VALUE.toInt()) l = Short.MAX_VALUE.toInt()
                            if (l < Short.MIN_VALUE.toInt()) l = Short.MIN_VALUE.toInt()
                            if (r > Short.MAX_VALUE.toInt()) r = Short.MAX_VALUE.toInt()
                            if (r < Short.MIN_VALUE.toInt()) r = Short.MIN_VALUE.toInt()
                            out[p] = l.toShort(); out[p+1] = r.toShort(); p += 2
                        }
                        track.write(out, 0, out.size)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "playAllWavPreviewKotlin: streaming error ${e.message}", e)
                } finally {
                    // fechar streams
                    streams?.forEach { s -> try { s.close() } catch (_: Throwable) {} }
                    previewStreams = null
                    try { track.stop(); track.release() } catch (_: Throwable) {}
                    if (audioTrack === track) audioTrack = null
                    currentKotlinTracks = null
                }
            }
            previewThread?.start()
            return true
        } catch (_: Throwable) {
            return false
        }
    }
}
