defmodule LlmProvider.OpenAI do
  @moduledoc """
  Implementation of the LlmProvider.Behaviour for OpenAI models.
  """
  @behaviour LlmProvider.Behaviour

  require Logger

  @base_url "https://api.openai.com/v1"
  @max_tokens 1024
  @config_key :openai_api_key

  @impl true
  def name, do: "OpenAI"

  @impl true
  def list_models() do
    api_key = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(api_key) do
      # Return empty list if no API key is configured
      []
    else
      url = "#{@base_url}/models"

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      case HTTPoison.get(url, headers) do
        {:ok, %{status_code: 200, body: body}} ->
          body
          |> Jason.decode!()
          |> Map.get("data", [])
          |> Enum.filter(fn model ->
            # Filter for code-capable models
            model_id = Map.get(model, "id", "")
            String.contains?(model_id, "gpt")
          end)
          |> Enum.map(fn %{"id" => id} ->
            %{id: id, name: id}
          end)

        {:ok, %{status_code: status_code, body: body}} ->
          {:error, "OpenAI returned status #{status_code}: #{body}"}

        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def generate_code(prompt, model, pid) do
    api_key = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(api_key) do
      # Send error with provider info
      send(pid, {:provider_not_configured, __MODULE__})
      :ok
    else
      url = "#{@base_url}/chat/completions"

      # Use the standardized system prompt
      system_prompt = LlmProvider.system_prompt()

      # Prepare the request body
      body =
        Jason.encode!(%{
          model: model,
          max_tokens: @max_tokens,
          messages: [
            %{role: "system", content: system_prompt},
            %{role: "user", content: prompt}
          ],
          stream: true
        })

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      try do
        # Stream the response
        case HTTPoison.post(url, body, headers,
               stream_to: self(),
               async: :once,
               timeout: 60000,
               recv_timeout: 60000
             ) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            receive_openai_response(id, pid, "", "")

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
  def generate_chat_response(messages, model, pid) do
    api_key = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(api_key) do
      # Send error with provider info
      send(pid, {:provider_not_configured, __MODULE__})
      :ok
    else
      url = "#{@base_url}/chat/completions"

      # Prepare the request body
      body =
        Jason.encode!(%{
          model: model,
          max_tokens: @max_tokens,
          messages: messages,
          stream: true
        })

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]

      try do
        # Stream the response
        case HTTPoison.post(url, body, headers,
               stream_to: self(),
               async: :once,
               timeout: 60000,
               recv_timeout: 60000
             ) do
          {:ok, %HTTPoison.AsyncResponse{id: id}} ->
            receive_openai_chat_response(id, pid, "", "")

          {:error, reason} ->
            error_message = "Error generating response: #{inspect(reason)}"
            send(pid, {:chat_complete, error_message})
        end

        :ok
      rescue
        e ->
          error_message = "Error generating response: #{inspect(e)}"
          send(pid, {:chat_complete, error_message})
          :ok
      end
    end
  end

  @impl true
  def example_config,
    do: %{
      @config_key => "System.fetch_env!(\"LB_VIBE_OPENAI_API_KEY\")"
    }

  @impl true
  def config_additional_info,
    do:
      "OpenAI models require an API key. You can obtain one at https://platform.openai.com/api-keys"

  # Helper function to stream the response from OpenAI
  defp receive_openai_response(id, pid, chunk_acc, result_acc) do
    receive do
      response -> handle_openai_response(response, id, pid, chunk_acc, result_acc)
    after
      60000 -> send(pid, {:generation_complete, result_acc})
    end
  end

  # Helper function to stream the chat response from OpenAI
  defp receive_openai_chat_response(id, pid, chunk_acc, result_acc) do
    receive do
      response -> handle_openai_chat_response(response, id, pid, chunk_acc, result_acc)
    after
      60000 -> send(pid, {:chat_complete, result_acc})
    end
  end

  defp handle_openai_response(response, id, pid, chunk_acc, result_acc) do
    case response do
      %HTTPoison.AsyncStatus{id: ^id, code: code} when code in 200..299 ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncHeaders{id: ^id} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

        {text, incomplete_chunk} = parse_sse_chunk(chunk_acc <> chunk)

        if text != "" do
          send(pid, {:code_chunk, text})
        end

        receive_openai_response(id, pid, incomplete_chunk, result_acc <> text)

      %HTTPoison.AsyncEnd{id: ^id} ->
        send(pid, {:generation_complete, result_acc})

      unknown_response ->
        Logger.warning("handle_openai_response unknown_response: #{inspect(unknown_response)}")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_response(id, pid, chunk_acc, result_acc)
    end
  end

  defp handle_openai_chat_response(response, id, pid, chunk_acc, result_acc) do
    case response do
      %HTTPoison.AsyncStatus{id: ^id, code: code} when code in 200..299 ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_chat_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncHeaders{id: ^id} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_chat_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

        {text, incomplete_chunk} = parse_sse_chunk(chunk_acc <> chunk)

        if text != "" do
          send(pid, {:response_chunk, text})
        end

        receive_openai_chat_response(id, pid, incomplete_chunk, result_acc <> text)

      %HTTPoison.AsyncEnd{id: ^id} ->
        send(pid, {:chat_complete, result_acc})

      unknown_response ->
        Logger.warning(
          "handle_openai_chat_response unknown_response: #{inspect(unknown_response)}"
        )

        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_openai_chat_response(id, pid, chunk_acc, result_acc)
    end
  end

  # Parse Server-Sent Events (SSE) format
  defp parse_sse_chunk(chunk) do
    # Split the chunk into lines
    lines = String.split(chunk, "\n")

    # Process each line and extract content
    {text, remaining} = process_sse_lines(lines, "", "")

    {text, remaining}
  end

  defp process_sse_lines([], text_acc, remaining_acc) do
    {text_acc, remaining_acc}
  end

  defp process_sse_lines([line | rest], text_acc, remaining_acc) do
    if String.starts_with?(line, "data: ") do
      data_str = String.trim(String.replace(line, "data: ", ""))

      # Handle [DONE] marker
      if data_str == "[DONE]" do
        process_sse_lines(rest, text_acc, remaining_acc)
      else
        # Parse JSON data
        case Jason.decode(data_str) do
          {:ok, data} ->
            # Extract content from the delta if present
            new_content = extract_content_from_delta(data)
            process_sse_lines(rest, text_acc <> new_content, remaining_acc)

          _ ->
            # If we can't parse, add to remaining
            process_sse_lines(rest, text_acc, remaining_acc <> line <> "\n")
        end
      end
    else
      # Non-data line, add to remaining
      if String.trim(line) != "" do
        process_sse_lines(rest, text_acc, remaining_acc <> line <> "\n")
      else
        process_sse_lines(rest, text_acc, remaining_acc)
      end
    end
  end

  defp extract_content_from_delta(data) do
    case data do
      # Regular content chunk
      %{"choices" => [%{"delta" => %{"content" => content}} | _]} when is_binary(content) ->
        content

      # First chunk with role but no content
      %{"choices" => [%{"delta" => %{"role" => "assistant"}} | _]} ->
        ""

      # Last chunk with finish_reason
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"} | _]} ->
        ""

      # Any other format
      _ ->
        ""
    end
  end
end
