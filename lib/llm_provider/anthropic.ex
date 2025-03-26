defmodule LlmProvider.Anthropic do
  @moduledoc """
  Implementation of the LlmProvider.Behaviour for Anthropic's Claude models.
  """
  # use LlmProvider
  @behaviour LlmProvider.Behaviour

  require Logger

  @base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"
  @config_key :anthropic_api_key

  @impl true
  def name, do: "Anthropic"

  @impl true
  def list_models() do
    api_key = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(api_key) do
      []  # Return empty list if no API key is configured
    else
      url = "#{@base_url}/models"

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", @anthropic_version},
        {"Content-Type", "application/json"}
      ]

      case HTTPoison.get(url, headers) do
        {:ok, %{status_code: 200, body: body}} ->
          body
          |> Jason.decode!()
          |> Map.get("data", [])
          |> Enum.map(fn %{"id" => id, "display_name" => display_name} ->
            %{id: id, name: display_name}
          end)

        {:ok, %{status_code: status_code, body: body}} ->
          {:error, "Anthropic returned status #{status_code}: #{body}"}

        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def generate_code(prompt, model, pid) do
    api_key = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(api_key) do
      send(pid, {:provider_not_configured, __MODULE__})  # Send error with provider info
      :ok
    else
      # Initialize Anthropic client
      client = Anthropix.init(api_key)

      # Prepare the system prompt
      system_prompt = """
      You are an expert Elixir developer. Generate clean, idiomatic Elixir code based on the user's request.
      Only respond with code. Do not include explanations or markdown formatting.
      """

      # Prepare the messages
      messages = [
        %{role: "user", content: prompt}
      ]

      # Stream the response
      try do
        {:ok, stream} = Anthropix.chat(client, [
          model: model,
          system: system_prompt,
          messages: messages,
          stream: true
        ])

        # Accumulate the full response
        full_response =
          stream
          |> Stream.map(fn chunk ->
            text = get_text_from_chunk(chunk)
            if text && text != "", do: send(pid, {:code_chunk, text})
            text || ""
          end)
          |> Enum.join("")

        send(pid, {:generation_complete, full_response})
        :ok
      rescue
        e ->
          error_message = "# Error generating code: #{inspect(e)}"
          send(pid, {:generation_complete, error_message})
          :ok
      end
    end
  end

  @impl true
  def example_config, do: %{
    @config_key => "System.fetch_env!(\"LB_VIBE_ANTHROPIC_API_KEY\")"
  }

  @impl true
  def config_additional_info, do: "Anthropic's Claude models require an API key. You can obtain one at https://console.anthropic.com/settings/keys"

  defp get_text_from_chunk(%{"delta" => %{"text" => text}}), do: text
  defp get_text_from_chunk(%{"delta" => %{"content" => [%{"text" => text}]}}), do: text
  defp get_text_from_chunk(%{"delta" => %{"content" => content}}) when is_list(content) do
    Enum.find_value(content, fn
      %{"text" => text} -> text
      _ -> nil
    end)
  end
  defp get_text_from_chunk(_), do: nil
end
