defmodule MobScreencast.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobScreencast.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)
  @android %{platform: :android, device: :emulator}
  @ios %{platform: :ios, device: :simulator}

  # Stands in for :mob_screencast_nif. Answers come from the calling test's
  # process dictionary (run/2 runs in the test process), so tests stay async.
  defmodule StubNif do
    def screencast_stop_stream, do: answer(:stop)
    def screencast_service_declared, do: answer(:declared)

    defp answer(key) do
      case Process.get({__MODULE__, key}) do
        {:nif_error, reason} -> :erlang.nif_error(reason)
        value -> value
      end
    end
  end

  defp run_with(ctx, stop, declared) do
    Process.put({StubNif, :stop}, stop)
    Process.put({StubNif, :declared}, declared)
    result = SelfTest.run(ctx, StubNif)
    assert Mob.Plugin.SelfTest.result?(result), "#{inspect(result)} is not a self-test result"
    result
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "passes when stop_stream answers :ok and the service lookup answers true" do
    assert run_with(@android, :ok, true) == :pass
    assert run_with(@ios, :ok, true) == :pass
  end

  test "an Android host without ScreencastService is a skip naming the missing service" do
    assert run_with(@android, :ok, false) ==
             {:skip, "host lacks <service io.mob.screencast.ScreencastService>"}

    assert run_with(@android, :ok, {:error, :not_media_projection}) ==
             {:skip,
              "host declares <service io.mob.screencast.ScreencastService> without " <>
                ~s(android:foregroundServiceType="mediaProjection")}
  end

  test "the missing-service skip is only reached after stop_stream proved the bridge" do
    assert {:fail, reason} = run_with(@android, {:error, :bridge_not_registered}, false)
    assert reason =~ "screencast_stop_stream/0 returned {:error, :bridge_not_registered}"
    assert reason =~ "MobScreencastBridge was never registered"
  end

  test "an unregistered bridge or missing Activity in the service lookup is a failure" do
    assert {:fail, reason} = run_with(@android, :ok, {:error, :no_activity})
    assert reason =~ "MobScreencastBridge has no Activity"

    assert {:fail, reason} = run_with(@android, :ok, {:error, :bridge_not_registered})
    assert reason =~ "screencast_service_declared/0 on android returned"
  end

  test "iOS has no host service to miss: false there is a failure, not a skip" do
    assert {:fail, reason} = run_with(@ios, :ok, false)
    assert reason == "screencast_service_declared/0 on ios returned false, expected true"
  end

  test "unexpected answers fail, naming the call, the answer and what was expected" do
    assert run_with(@android, :error, true) ==
             {:fail, "screencast_stop_stream/0 on android returned :error, expected :ok"}

    assert run_with(@android, :ok, :maybe) ==
             {:fail, "screencast_service_declared/0 on android returned :maybe, expected true"}
  end

  test "nif_not_loaded from either call is a failure naming the NIF, not a raise" do
    assert {:fail, reason} = run_with(@android, {:nif_error, :nif_not_loaded}, true)
    assert reason =~ "mob_screencast_nif is not linked into this build"
    assert reason =~ "nif_not_loaded"

    assert {:fail, reason} = run_with(@ios, :ok, {:nif_error, :nif_not_loaded})
    assert reason =~ "mob_screencast_nif is not linked into this build"
  end

  test "on a host with no native library linked run/1 fails instead of raising" do
    for ctx <- [@android, @ios] do
      assert {:fail, reason} = SelfTest.run(ctx)
      assert reason =~ "mob_screencast_nif is not linked into this build"
      assert reason =~ "nif_not_loaded"
    end
  end
end
