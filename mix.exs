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
    # constraint ("~> 0.6") when mob publishes. :mob_dev is test-only (the
    # manifest tests run the real pre-publish validator) and never ships.
    [
      {:mob, path: "../mob"},
      {:mob_dev, path: "../mob_dev", only: [:dev, :test], runtime: false}
    ]
  end
end
