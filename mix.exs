defmodule MobScreencast.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_screencast,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    # Local path dep while the plugin system is dogfooded; switch to the Hex
    # constraint ("~> 0.6") when mob publishes.
    [
      {:mob, path: "../mob"}
    ]
  end
end
