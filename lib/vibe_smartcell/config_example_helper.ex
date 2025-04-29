defmodule VibeSmartcell.ConfigExampleHelper do
  @moduledoc """
  Helper module to generate configuration example strings for providers.
  """

  @doc """
  Generates a formatted configuration example string for the given providers.
  """
  def generate(providers, message) do
    providers
    |> List.wrap()
    |> Enum.map(fn provider ->
      Enum.map(provider.example_config, fn {k, v} ->
        """
        #     #{k}: #{v},
        """
      end)
      |> Enum.join()
      |> String.trim()
      |> then(fn config_example_lines ->
        """
        #   # #{provider.name} configuration:
        #{config_example_lines}
        #   # #{provider.config_additional_info}
        """
      end)
    end)
    |> Enum.join("#\n")
    |> String.trim()
    |> then(fn providers_config_example ->
      """
      #{message}

      Add to your notebook setup:

      Application.put_all_env(
        vibe_smartcell: [
      #{providers_config_example}
        ]
      )

      About Livebook secrets env: https://hexdocs.pm/livebook/shared_secrets.html
      """
    end)
    |> String.trim()
  end
end
