defmodule MobScreencast do
  @moduledoc """
  Capture the **device's own screen** as an H264 stream, from inside a mob app — the
  in-app replacement for host-side `adb screenrecord`, so a NAT'd phone can publish its
  screen with no adb and no host on the same network.

  The native side captures the display (Android `MediaProjection`, iOS `ReplayKit` /
  `ScreenCaptureKit`) and hardware-encodes it to **H264 on-device** (`MediaCodec` /
  `VideoToolbox`), so the BEAM receives ready-to-send Annex-B NAL units rather than raw
  frames. That output drops straight into a WebRTC RTP payloader (mob_screencast pairs
  with sloppy_joe's `SloppyJoe.Media.Capture.H264`).

  ## Streaming

      MobScreencast.start_stream(socket, bitrate: 2_000_000, max_size: 1280)

  delivers each encoded access unit as a message to the calling process:

      handle_info({:screencast, :frame, %{bytes: nal_units, format: :h264,
                                          timestamp_ms: t, keyframe: kf?}}, socket)

    * `bytes` — one access unit of Annex-B H264 (`00 00 00 01` start codes); a
      keyframe frame is prefixed with SPS/PPS.
    * `keyframe` — true for an IDR (a freshly-joined decoder needs one; request the
      next via `request_keyframe/0`).

  Stop with `stop_stream/1`.

  ## Permission

  Screen capture needs explicit, per-session user consent (Android's
  `MediaProjection` system dialog; iOS ReplayKit's broadcast prompt). `start_stream`
  triggers it; `{:screencast, :permission, :granted | :denied}` reports the outcome.
  """
  @nif :mob_screencast_nif

  @type frame :: %{
          bytes: binary(),
          format: :h264,
          width: non_neg_integer(),
          height: non_neg_integer(),
          timestamp_ms: non_neg_integer(),
          keyframe: boolean()
        }

  @doc """
  Start capturing + encoding the screen. Frames arrive as `{:screencast, :frame, map}`
  messages to the calling process (see the module doc).

  Options:
    * `:bitrate` — target encoder bitrate in bits/sec (default `2_000_000`).
    * `:max_size` — cap the longer screen edge to this many px, preserving aspect
      (default: native resolution). Lower = less bandwidth/CPU. Currently honored
      on Android only; the iOS encoder captures at native resolution.
    * `:fps` — target frame rate (default `30`).
    * `:keyframe_interval_ms` — force an IDR at least this often (default `2000`).
  """
  @spec start_stream(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_stream(socket, opts \\ []) do
    @nif.screencast_start_stream(:json.encode(stream_opts(opts)))
    socket
  end

  @doc """
  Build the config map passed to `screencast_start_stream/1`. Pure function
  exposed so tests can pin defaults + serialisation without going through the
  NIF. Note `:max_size` is currently honored on Android only — the iOS encoder
  captures at native resolution (TODO in the iOS NIF).
  """
  @spec stream_opts(keyword()) :: map()
  def stream_opts(opts) do
    %{
      "bitrate" => Keyword.get(opts, :bitrate, 2_000_000),
      "fps" => Keyword.get(opts, :fps, 30),
      "keyframe_interval_ms" => Keyword.get(opts, :keyframe_interval_ms, 2_000)
    }
    |> put_optional("max_size", opts[:max_size])
  end

  @doc "Stop the active screen-capture session."
  @spec stop_stream(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_stream(socket) do
    @nif.screencast_stop_stream()
    socket
  end

  @doc """
  Ask the encoder to emit a keyframe (IDR) on the next frame — call this when a new
  viewer joins so its decoder can start without waiting for the periodic keyframe.
  """
  @spec request_keyframe() :: :ok
  def request_keyframe do
    @nif.screencast_request_keyframe()
    :ok
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
