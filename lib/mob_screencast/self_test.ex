defmodule MobScreencast.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  Two NIF calls, no consent dialog, no capture:

    1. `screencast_stop_stream/0` must answer `:ok`. Nothing is capturing, so
       it is a no-op, but it goes through the native code:
       * Android: the zig NIF calls `MobScreencastBridge.screencast_stop_stream()`
         over JNI (an idle `stopInternal()`). `:ok` proves the NIF is linked
         and `nativeRegister` cached the bridge class and method IDs;
         `{:error, :bridge_not_registered}` means `MobPluginBootstrap` never
         called `register()` (or a method-ID lookup failed), so no call can
         ever reach Kotlin: a failure.
       * iOS: the Objective-C NIF asks `RPScreenRecorder` to stop (with
         nothing recording, ReplayKit's completion error is ignored) and
         answers `:ok`. That proves the NIF table is linked and `nif_init`
         ran, not that ReplayKit can record on this device.
    2. `screencast_service_declared/0`:
       * Android: the bridge asks `PackageManager.getServiceInfo/2` whether
         the host's AndroidManifest declares
         `io.mob.screencast.ScreencastService`, the typed foreground service
         every capture runs in. The plugin cannot contribute it (the manifest
         lists it under `:host_requirements`), and a host without it builds
         and boots clean, then throws a `SecurityException` at first capture.
         `true` (declared, `foregroundServiceType` includes
         `mediaProjection`) passes. `false` (not declared, e.g. a
         `mix mob.new --blank` host) and `{:error, :not_media_projection}`
         (declared without the `mediaProjection` type, API 29+) are skips
         that name what the host lacks: the plugin's native side answered,
         the host is incomplete. `{:error, :no_activity}` (the bootstrap
         never handed the bridge an Activity, so `start_stream/2` could not
         launch the consent dialog either) and `{:error, :lookup_failed}`
         (the lookup threw, or left a Java exception pending) are failures.
       * iOS: always `true`; in-app ReplayKit needs nothing declared by the
         host (no broadcast extension, no Info.plist key). Reaching it proves
         the export is in the linked NIF table.

  Expected: an iOS simulator passes. An Android emulator running a host that
  declares the service passes; on a blank host it skips with
  `"host lacks <service io.mob.screencast.ScreencastService>"`. A real frame
  needs the per-session consent dialog, which is a person's tap and the
  feature, not the proof.

  The host stub's `nif_not_loaded` is a failure. Run it while the host is not
  capturing: `screencast_stop_stream/0` would stop an active capture.
  """
  @behaviour Mob.Plugin.SelfTest

  @service "io.mob.screencast.ScreencastService"

  @impl true
  def run(ctx), do: run(ctx, :mob_screencast_nif)

  @doc false
  # `nif` is the NIF module, injectable so unit tests can pass a stub.
  @spec run(Mob.Plugin.SelfTest.ctx(), module()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif) do
    with :ok <- stop_stream(nif.screencast_stop_stream(), platform) do
      service_declared(nif.screencast_service_declared(), platform)
    end
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:fail, "mob_screencast_nif is not linked into this build: #{Exception.message(e)}"}
  end

  defp stop_stream(:ok, _platform), do: :ok

  defp stop_stream({:error, :bridge_not_registered}, _platform) do
    {:fail,
     "screencast_stop_stream/0 returned {:error, :bridge_not_registered}: the Kotlin " <>
       "MobScreencastBridge was never registered (MobPluginBootstrap did not call " <>
       "register(), or a method-ID lookup failed), expected :ok"}
  end

  defp stop_stream(other, platform) do
    {:fail, "screencast_stop_stream/0 on #{platform} returned #{inspect(other)}, expected :ok"}
  end

  defp service_declared(true, _platform), do: :pass

  defp service_declared(false, :android), do: {:skip, "host lacks <service #{@service}>"}

  defp service_declared({:error, :not_media_projection}, :android) do
    {:skip,
     "host declares <service #{@service}> without " <>
       ~s(android:foregroundServiceType="mediaProjection")}
  end

  defp service_declared({:error, :no_activity}, :android) do
    {:fail,
     "screencast_service_declared/0 returned {:error, :no_activity}: MobScreencastBridge " <>
       "has no Activity (MobActivityAware.setActivity never called), so start_stream/2 " <>
       "cannot launch the consent dialog either"}
  end

  defp service_declared(other, platform) do
    {:fail,
     "screencast_service_declared/0 on #{platform} returned #{inspect(other)}, expected true"}
  end
end
