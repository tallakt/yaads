defmodule ADS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tallakt/yaads"

  def project do
    [
      app: :yaads,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      description:
        "Beckhoff ADS in pure Elixir: a client for TwinCAT PLCs that reads, writes and " <>
          "watches variables by name, over TCP or Secure ADS (TLS), and finds PLCs and adds and deletes " <>
          "routes over UDP, without C in the BEAM.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      # The fake PLC and the hostile server are the tests' own.
      test_coverage: [
        summary: [threshold: 88],
        ignore_modules: [
          ADS.Test.FakePLC,
          ADS.Test.FakePLC.Connection,
          ADS.Test.FakeDiscovery,
          ADS.Test.Flaky,
          ADS.Test.Hostile
        ]
      ],
      dialyzer: [
        # Kept between runs, and between CI jobs by its cache.
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        # For mix ads.route.
        plt_add_apps: [:mix],
        flags: [:error_handling, :extra_return, :unmatched_returns]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "NOTICE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Client: [
          ADS,
          ADS.Client,
          ADS.Discovery,
          ADS.Route,
          ADS.Symbol,
          ADS.DataType,
          ADS.ReturnCode
        ],
        Values: [ADS.Type],
        "Secure ADS": [ADS.Certificate, ADS.Secure],
        Encoding: [ADS.NetId, ADS.AMS, ADS.Command, ADS.Sum]
      ]
    ]
  end

  def application do
    [
      # OTP's own TLS, for Secure ADS
      extra_applications: [:crypto, :public_key, :ssl]
    ]
  end

  defp deps do
    [
      # Only for the fuzz and property tests.
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
