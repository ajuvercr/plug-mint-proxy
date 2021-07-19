defmodule PlugMintProxy.MixProject do
  use Mix.Project

  @version "0.2.0"
  @github_link "https://github.com/madnificent/plug-mint-proxy"

  def project do
    [
      app: :plug_mint_proxy,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PlugMintProxy, []},
      env: []
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 0.1.0"},
      {:gun, "~> 2.0.0-rc.2"},
      {:mint, "~> 0.4.0"},
      {:plug, "~> 1.10.4"},
      {:plug_cowboy, "~> 2.4.0"}
    ]
  end

  defp package do
    [
      maintainers: ["Aad Versteden"],
      licenses: ["MIT License"],
      links: %{"GitHub" => @github_link}
    ]
  end
end
