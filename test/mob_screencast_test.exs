defmodule MobScreencastTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_screencast_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_screencast_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "declares the foreground-service permissions MediaProjection needs (API 34+ typed)",
         %{manifest: m} do
      assert "android.permission.FOREGROUND_SERVICE" in m.android.permissions
      assert "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" in m.android.permissions
    end

    test "declares the manual <service> host requirement (the silent-failure landmine)",
         %{manifest: m} do
      assert [req] = m.host_requirements
      assert req =~ "io.mob.screencast.ScreencastService"
      assert req =~ "foregroundServiceType=\"mediaProjection\""
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "NIF stub agreement" do
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_screencast_nif)
    end

    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_screencast_nif.module_info(:exports)

      for fa <- [
            screencast_start_stream: 1,
            screencast_stop_stream: 0,
            screencast_request_keyframe: 0
          ] do
        assert fa in exports, "#{inspect(fa)} missing from mob_screencast_nif exports"
      end
    end

    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_screencast_nif.screencast_stop_stream()
      end
    end
  end

  describe "stream_opts/1" do
    test "defaults: 2 Mbps, 30 fps, 2 s keyframe interval, no max_size cap" do
      assert MobScreencast.stream_opts([]) == %{
               "bitrate" => 2_000_000,
               "fps" => 30,
               "keyframe_interval_ms" => 2_000
             }
    end

    test "max_size is included only when given (Android-only cap)" do
      assert MobScreencast.stream_opts(max_size: 640)["max_size"] == 640
      refute Map.has_key?(MobScreencast.stream_opts([]), "max_size")
    end

    test "every option overrides its default" do
      assert MobScreencast.stream_opts(bitrate: 500_000, fps: 15, keyframe_interval_ms: 1_000) ==
               %{"bitrate" => 500_000, "fps" => 15, "keyframe_interval_ms" => 1_000}
    end

    test "the opts map round-trips through :json (what the NIF actually receives)" do
      decoded =
        MobScreencast.stream_opts(max_size: 1280)
        |> :json.encode()
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["bitrate"] == 2_000_000
      assert decoded["max_size"] == 1280
    end
  end

  describe "public API surface" do
    test "exports the streaming surface" do
      exports = MobScreencast.__info__(:functions)

      for fa <- [start_stream: 2, stop_stream: 1, request_keyframe: 0, stream_opts: 1] do
        assert fa in exports, "#{inspect(fa)} missing from MobScreencast"
      end
    end
  end
end
