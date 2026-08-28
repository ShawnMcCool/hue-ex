defmodule Hue.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/ShawnMcCool/hue-ex"

  def project do
    [
      app: :hue,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # precommit runs dialyzer in :test, where test/support is compiled and
      # calls into ExUnit.
      dialyzer: [plt_add_apps: [:ex_unit]],
      description: description(),
      package: package(),
      docs: docs(),
      name: "Hue",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:server_sent_events, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:color, "~> 0.13"},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp description do
    "A client for the Philips Hue CLIP v2 local API — resources, eventstream, " <>
      "discovery, certificate pinning, and gamut-correct colour."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Shawn McCool"],
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        {"examples/walkthrough.livemd", filename: "walkthrough"},
        {"examples/control_panel.livemd", filename: "control_panel"}
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Hue, Hue.Client, Hue.Resource, Hue.Error],
        Setup: [Hue.Discovery, Hue.Bridge, Hue.Bridge.Info, Hue.Pairing, Hue.Transport],
        Events: [Hue.Events, Hue.Event],
        Colour: [Hue.Color, Hue.Color.Gamut]
      ]
    ]
  end
end
