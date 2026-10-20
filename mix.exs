defmodule PhoenixMountable.MixProject do
  use Mix.Project

  @version "0.2.2"
  @source_url "https://github.com/hattoriai/phoenix_mountable"

  def project do
    [
      app: :phoenix_mountable,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "PhoenixMountable",
      description:
        "Build libraries that mount into a Phoenix app: routes, LiveViews, assets, auth, processes and migrations in one package.",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql, :igniter]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PhoenixMountable.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:nimble_options, "~> 1.0"},

      # Optional: the web side (mounting) needs Phoenix and LiveView. A core
      # package that only uses migrations or processes does not.
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:phoenix_html, "~> 4.0", optional: true},
      {:plug, "~> 1.14", optional: true},

      # Optional: migrations and installers
      {:ecto_sql, "~> 3.10", optional: true},
      {:igniter, "~> 0.6", optional: true},

      # Test and dev
      {:postgrex, "~> 0.19", only: [:dev, :test]},
      {:myxql, "~> 0.7", only: [:dev, :test]},
      {:ecto_sqlite3, "~> 0.17", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "compile --warnings-as-errors"]
    ]
  end

  defp package do
    [
      maintainers: ["Rui Freitas"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files:
        ~w(lib priv/static media/banner.png mix.exs package.json README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      logo: "media/logo.svg",
      assets: %{"media" => "media"},
      extras: [
        "README.md",
        "guides/building-a-mountable-library.md",
        "guides/assets.md",
        "guides/migrations.md",
        "guides/processes.md",
        "guides/installers.md",
        "guides/testing.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [Guides: ~r/guides\//],
      groups_for_modules: [
        Core: [
          PhoenixMountable,
          PhoenixMountable.Definition,
          PhoenixMountable.Routes,
          PhoenixMountable.Mount,
          PhoenixMountable.Path,
          PhoenixMountable.Layout,
          PhoenixMountable.HTML
        ],
        Assets: ~r/PhoenixMountable\.Assets/,
        Processes: [
          PhoenixMountable.Supervisor,
          PhoenixMountable.Singleton,
          PhoenixMountable.PubSub,
          PhoenixMountable.Telemetry
        ],
        Migrations: ~r/PhoenixMountable\.(Migration|Backfill)/,
        Installers: [
          PhoenixMountable.Install,
          PhoenixMountable.Igniter,
          PhoenixMountable.Igniter.HostAssets
        ],
        Testing: [PhoenixMountable.TestHost, PhoenixMountable.Test]
      ]
    ]
  end
end
