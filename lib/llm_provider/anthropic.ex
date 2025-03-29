defmodule LlmProvider.Anthropic do
  @moduledoc """
  Implementation of the LlmProvider.Behaviour for Anthropic's Claude models.
  """
  @behaviour LlmProvider.Behaviour

  require Logger

  @base_url "https://api.anthropic.com/v1"
  @anthropic_version "2023-06-01"
  @max_tokens 1024
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
      url = "#{@base_url}/messages"

      # Use the standardized system prompt
      system_prompt = LlmProvider.system_prompt()

      # Prepare the request body
      body = Jason.encode!(%{
        model: model,
        max_tokens: @max_tokens,
        system: system_prompt,
        messages: [
          %{role: "user", content: prompt}
        ],
        stream: true
      })

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", @anthropic_version},
        {"Content-Type", "application/json"}
      ]

      try do
        # Stream the response
        case HTTPoison.post(url, body, headers, [stream_to: self(), async: :once, timeout: 60000, recv_timeout: 60000]) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            receive_anthropic_response(id, pid, "", "")

          {:error, reason} ->
            error_message = "# Error generating code: #{inspect(reason)}"
            send(pid, {:generation_complete, error_message})
        end

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

  # Helper function to stream the response from Anthropic
  defp receive_anthropic_response(id, pid, chunk_acc, result_acc) do
    receive do
      response -> handle_anthropic_response(response, id, pid, chunk_acc, result_acc)
    after
      60000 -> send(pid, {:generation_complete, result_acc})
    end
  end

  defp handle_anthropic_response(response, id, pid, chunk_acc, result_acc) do
    case response do
      %HTTPoison.AsyncStatus{id: ^id, code: code} when code in 200..299 ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_anthropic_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncHeaders{id: ^id} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_anthropic_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

        {text, incomplete_chunk} = parse_sse_chunk(chunk_acc <> chunk)
        if text != "" do
          send(pid, {:code_chunk, text})
        end
        receive_anthropic_response(id, pid, incomplete_chunk, result_acc <> text)

      %HTTPoison.AsyncEnd{id: ^id} ->
        send(pid, {:generation_complete, result_acc})

      unknown_response ->
        Logger.warning("handle_anthropic_response unknown_response: #{inspect(unknown_response)}")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_anthropic_response(id, pid, chunk_acc, result_acc)
    end
  end

  # Parse Server-Sent Events (SSE) format
  defp parse_sse_chunk(chunk) do
    # Split the chunk into lines
    lines = String.split(chunk, "\n")

    # Process complete events (event + data pairs)
    {events, remaining} = extract_complete_events(lines, [], "")

    # Extract text from content_block_delta events
    text = extract_text_from_events(events)

    {text, remaining}
  end

  defp extract_complete_events([], events_acc, remaining) do
    {events_acc, remaining}
  end

  defp extract_complete_events([line | rest], events_acc, current_event) do
    cond do
      # Start of a new event
      String.starts_with?(line, "event: ") ->
        event_type = String.trim(String.replace(line, "event: ", ""))
        extract_complete_events(rest, events_acc, %{type: event_type, data: nil})

      # Data for current event
      String.starts_with?(line, "data: ") and is_map(current_event) ->
        data_str = String.trim(String.replace(line, "data: ", ""))
        data = case Jason.decode(data_str) do
          {:ok, parsed} -> parsed
          _ -> data_str
        end

        event = Map.put(current_event, :data, data)

        # Empty line marks end of an event
        if Enum.at(rest, 0) == "" do
          extract_complete_events(Enum.drop(rest, 1), [event | events_acc], "")
        else
          extract_complete_events(rest, events_acc, event)
        end

      # Empty line without a complete event
      line == "" ->
        extract_complete_events(rest, events_acc, current_event)

      # Any other line - keep as part of remaining
      true ->
        remaining = if current_event == "" do
          line
        else
          # If we have a partial event, keep it in the remaining
          Jason.encode!(current_event) <> "\n" <> line
        end

        {events_acc, remaining <> "\n" <> Enum.join(rest, "\n")}
    end
  end

  defp extract_text_from_events(events) do
    events
    |> Enum.filter(fn
      %{type: "content_block_delta"} -> true
      _ -> false
    end)
    |> Enum.map(fn
      %{data: %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}} -> text
      %{data: %{"delta" => %{"type" => "text_delta", "text" => text}}} -> text
      _ -> ""
    end)
    |> Enum.join("")
  end
end
