defmodule VibeSmartcell.MixProject do
  use Mix.Project

  def project do
    [
      app: :vibe_smartcell,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {VibeSmartcell.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:anthropix, "~> 0.6"},
      {:kino, "~> 0.15.0"},
      {:httpoison, "~> 2.0"},
    ]
  end
end
