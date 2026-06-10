// MobScreencastBridge — the plugin-owned Android bridge for mob_screencast.
//
// Captures the device screen with MediaProjection, encodes it to H264 with a
// MediaCodec AVC encoder fed by a VirtualDisplay, and pushes each Annex-B access unit
// to the BEAM via the zig NIF's nativeDeliverScreencastFrame. The native thunks
// (nativeRegister + nativeDeliverScreencastFrame) are exported from
// priv/native/jni/mob_screencast_nif.zig.
//
// Implements MobActivityAware so it can reach the host Activity for the one-time
// MediaProjection consent dialog (launched from a headless Fragment, so no MainActivity
// change). NOTE: on Android 14+ (API 34) a MediaProjection capture must run inside a
// foreground service of type mediaProjection — an AndroidManifest <service> the plugin
// manifest can't yet contribute (see PLAN.md). This first cut targets API <= 33 (the
// Moto G is API 30), where MediaProjection runs directly.
package io.mob.screencast

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.util.Log
import android.view.Surface
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.lang.ref.WeakReference
import org.json.JSONObject

object MobScreencastBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:screencast, :frame, %{bytes, width, height, format: :h264, timestamp_ms, keyframe}}
    @JvmStatic external fun nativeDeliverScreencastFrame(
        pid: Long, bytes: ByteArray, width: Int, height: Int, timestampMs: Long, keyframe: Int,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // ── Capture session state ──────────────────────────────────────────────
    private var streamPid: Long = 0L
    private var bitrate = 2_000_000
    private var fps = 30
    private var keyframeIntervalMs = 2_000
    private var maxSize = 0 // 0 = native resolution

    private var projection: MediaProjection? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null
    @Volatile private var running = false
    private var drainThread: Thread? = null
    private var csd: ByteArray? = null // SPS/PPS (Annex-B), prepended to keyframes

    // ── NIF entry points (called from zig) ─────────────────────────────────

    @JvmStatic
    fun screencast_start_stream(pid: Long, configJson: String) {
        if (running) stopInternal()
        streamPid = pid
        try {
            val cfg = JSONObject(configJson)
            bitrate = cfg.optInt("bitrate", 2_000_000)
            fps = cfg.optInt("fps", 30)
            keyframeIntervalMs = cfg.optInt("keyframe_interval_ms", 2_000)
            maxSize = cfg.optInt("max_size", 0)
        } catch (_: Throwable) {
        }

        val activity = activityRef?.get() as? FragmentActivity ?: run {
            Log.e("MobScreencast", "no FragmentActivity for the MediaProjection consent")
            return
        }
        // The NIF calls us on a BEAM thread; FragmentManager transactions (and the
        // consent dialog) must run on the main thread.
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            try {
                val frag = ScreencastConsentFragment()
                activity.supportFragmentManager.beginTransaction()
                    .add(frag, "mob_screencast_consent").commitNow()
            } catch (e: Throwable) {
                Log.e("MobScreencast", "consent launch failed: ${e.message}")
            }
        }
    }

    @JvmStatic
    fun screencast_stop_stream() = stopInternal()

    @JvmStatic
    fun screencast_request_keyframe() {
        try {
            encoder?.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
        } catch (_: Throwable) {
        }
    }

    // ── MediaProjection result → encoder + virtual display ─────────────────

    internal fun onProjectionResult(resultCode: Int, data: Intent?) {
        val activity = activityRef?.get()
        if (activity == null || data == null) return
        val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = mpm.getMediaProjection(resultCode, data) ?: return
        projection = proj
        // API 34 requires a registered callback; harmless earlier.
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() = stopInternal()
        }, null)

        val dm = activity.resources.displayMetrics
        val (w, h) = captureSize(dm.widthPixels, dm.heightPixels, maxSize)

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeIntervalMs / 1000f)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()
        encoder = codec
        inputSurface = surface

        virtualDisplay = proj.createVirtualDisplay(
            "mob_screencast", w, h, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null,
        )

        running = true
        drainThread = Thread { drainLoop(codec, w, h) }.also { it.start() }
    }

    private fun drainLoop(codec: MediaCodec, w: Int, h: Int) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val idx = codec.dequeueOutputBuffer(info, 10_000)
                if (idx < 0) continue
                val buf = codec.getOutputBuffer(idx)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buf.get(bytes)

                    val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                    if (isConfig) {
                        csd = bytes // SPS/PPS, already Annex-B
                    } else {
                        // Prepend SPS/PPS to keyframes so a freshly-joined decoder starts.
                        val out = if (isKey) (csd ?: ByteArray(0)) + bytes else bytes
                        nativeDeliverScreencastFrame(
                            streamPid, out, w, h, System.currentTimeMillis(), if (isKey) 1 else 0,
                        )
                    }
                }
                codec.releaseOutputBuffer(idx, false)
            }
        } catch (e: Throwable) {
            Log.e("MobScreencast", "drain failed: ${e.message}")
        }
    }

    @Synchronized
    private fun stopInternal() {
        running = false
        try { drainThread?.join(500) } catch (_: Throwable) {}
        drainThread = null
        try { virtualDisplay?.release() } catch (_: Throwable) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Throwable) {}
        try { inputSurface?.release() } catch (_: Throwable) {}
        try { projection?.stop() } catch (_: Throwable) {}
        virtualDisplay = null; encoder = null; inputSurface = null; projection = null; csd = null
    }

    // Cap the longer edge to maxSize (if set), preserve aspect, round to even (H264).
    private fun captureSize(w: Int, h: Int, max: Int): Pair<Int, Int> {
        if (max <= 0 || (w <= max && h <= max)) return even(w) to even(h)
        val scale = max.toDouble() / maxOf(w, h)
        return even((w * scale).toInt()) to even((h * scale).toInt())
    }

    private fun even(n: Int): Int = if (n % 2 == 0) n else n - 1
}

// Headless Fragment that launches the MediaProjection consent dialog and hands the
// result back to the bridge, so the plugin needs no MainActivity changes.
class ScreencastConsentFragment : Fragment() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val launcher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                MobScreencastBridge.onProjectionResult(result.resultCode, result.data)
            }
            parentFragmentManager.beginTransaction().remove(this).commitAllowingStateLoss()
        }
        val mpm = requireActivity()
            .getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        launcher.launch(mpm.createScreenCaptureIntent())
    }
}
