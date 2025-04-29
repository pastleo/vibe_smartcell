defmodule LlmProvider.Ollama do
  @moduledoc """
  Implementation of the LlmProvider.Behaviour for Ollama models.
  """
  @behaviour LlmProvider.Behaviour

  require Logger

  @config_key :ollama_base_url

  @impl true
  def name, do: "Ollama"

  @impl true
  def list_models() do
    base_url = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(base_url) do
      # Return empty list if base URL is not configured
      []
    else
      url = "#{base_url}/tags"

      headers = [
        {"Content-Type", "application/json"}
      ]

      case HTTPoison.get(url, headers) do
        {:ok, %{status_code: 200, body: body}} ->
          body
          |> Jason.decode!()
          |> Map.get("models", [])
          |> Enum.map(fn %{"name" => name} ->
            %{id: name, name: name}
          end)

        {:ok, %{status_code: status_code, body: body}} ->
          {:error, "Ollama returned status #{status_code}: #{body}"}

        {:error, reason} ->
          {:error, "HTTP request failed: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def generate_code(prompt, model, pid) do
    base_url = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(base_url) do
      # Send error with provider info
      send(pid, {:provider_not_configured, __MODULE__})
      :ok
    else
      url = "#{base_url}/generate"

      # Use the standardized system prompt
      system_prompt = LlmProvider.system_prompt()

      # Prepare the request body
      body =
        Jason.encode!(%{
          model: model,
          system: system_prompt,
          prompt: prompt,
          stream: true
        })

      headers = [
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
            receive_ollama_response(id, pid, "", "")

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
    base_url = Application.get_env(:vibe_smartcell, @config_key)

    if is_nil(base_url) do
      # Send error with provider info
      send(pid, {:provider_not_configured, __MODULE__})
      :ok
    else
      url = "#{base_url}/chat"

      # Convert messages to Ollama format
      # Extract system message if present
      {system_message, chat_messages} = extract_system_message(messages)

      # Prepare the request body
      body =
        Jason.encode!(%{
          model: model,
          system: system_message,
          messages: chat_messages,
          stream: true
        })

      headers = [
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
            receive_ollama_chat_response(id, pid, "", "")

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
      @config_key => "\"http://localhost:11434/api\""
    }

  @impl true
  def config_additional_info,
    do:
      "Ollama runs locally by default on port 11434. Make sure Ollama is installed and running. Visit https://ollama.com for installation instructions."

  # Helper function to extract system message from messages array
  defp extract_system_message(messages) do
    system_messages = Enum.filter(messages, fn %{role: role} -> role == "system" end)
    chat_messages = Enum.filter(messages, fn %{role: role} -> role != "system" end)

    system_content =
      case system_messages do
        [%{content: content} | _] -> content
        _ -> "You are a helpful assistant."
      end

    {system_content, chat_messages}
  end

  # Helper function to stream the response from Ollama
  defp receive_ollama_response(id, pid, chunk_acc, result_acc) do
    receive do
      response -> handle_ollama_response(response, id, pid, chunk_acc, result_acc)
    after
      60000 -> send(pid, {:generation_complete, result_acc})
    end
  end

  # Helper function to stream the chat response from Ollama
  defp receive_ollama_chat_response(id, pid, chunk_acc, result_acc) do
    receive do
      response -> handle_ollama_chat_response(response, id, pid, chunk_acc, result_acc)
    after
      60000 -> send(pid, {:chat_complete, result_acc})
    end
  end

  defp handle_ollama_response(response, id, pid, chunk_acc, result_acc) do
    case response do
      %HTTPoison.AsyncStatus{id: ^id, code: code} when code in 200..299 ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncHeaders{id: ^id} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

        {text, incomplete_chunk_line} =
          parse_response_chunk_lines(
            String.split(chunk_acc <> chunk, "\n"),
            ""
          )

        send(pid, {:code_chunk, text})
        receive_ollama_response(id, pid, incomplete_chunk_line, result_acc <> text)

      %HTTPoison.AsyncEnd{id: ^id} ->
        Logger.debug("AsyncEnd: #{chunk_acc}")
        send(pid, {:generation_complete, result_acc})

      unknown_response ->
        Logger.warning("handle_ollama_response unknown_response: #{inspect(unknown_response)}")
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_response(id, pid, chunk_acc, result_acc)
    end
  end

  defp parse_response_chunk_lines([incomplete_chunk_line | []], chunk_result_acc) do
    {chunk_result_acc, incomplete_chunk_line}
  end

  defp parse_response_chunk_lines([chunk_line | rest_chunk_line], chunk_result_acc) do
    parse_response_chunk_lines(
      rest_chunk_line,
      chunk_result_acc <> parse_response_chunk_line(chunk_line)
    )
  end

  defp parse_response_chunk_line(chunk_line) do
    case Jason.decode(chunk_line) do
      {:ok, %{"response" => text}} when is_binary(text) and byte_size(text) > 0 ->
        text

      _ ->
        Logger.warning("receive_ollama_response unknown chunk_line: #{chunk_line}")
        ""
    end
  end

  defp handle_ollama_chat_response(response, id, pid, chunk_acc, result_acc) do
    case response do
      %HTTPoison.AsyncStatus{id: ^id, code: code} when code in 200..299 ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_chat_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncHeaders{id: ^id} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_chat_response(id, pid, chunk_acc, result_acc)

      %HTTPoison.AsyncChunk{id: ^id, chunk: chunk} ->
        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})

        {text, incomplete_chunk_line} =
          parse_chat_response_chunk_lines(
            String.split(chunk_acc <> chunk, "\n"),
            ""
          )

        send(pid, {:response_chunk, text})
        receive_ollama_chat_response(id, pid, incomplete_chunk_line, result_acc <> text)

      %HTTPoison.AsyncEnd{id: ^id} ->
        Logger.debug("AsyncEnd: #{chunk_acc}")
        send(pid, {:chat_complete, result_acc})

      unknown_response ->
        Logger.warning(
          "handle_ollama_chat_response unknown_response: #{inspect(unknown_response)}"
        )

        HTTPoison.stream_next(%HTTPoison.AsyncResponse{id: id})
        receive_ollama_chat_response(id, pid, chunk_acc, result_acc)
    end
  end

  defp parse_chat_response_chunk_lines([incomplete_chunk_line | []], chunk_result_acc) do
    {chunk_result_acc, incomplete_chunk_line}
  end

  defp parse_chat_response_chunk_lines([chunk_line | rest_chunk_line], chunk_result_acc) do
    parse_chat_response_chunk_lines(
      rest_chunk_line,
      chunk_result_acc <> parse_chat_response_chunk_line(chunk_line)
    )
  end

  defp parse_chat_response_chunk_line(chunk_line) do
    case Jason.decode(chunk_line) do
      {:ok, %{"message" => %{"content" => text}}} when is_binary(text) and byte_size(text) > 0 ->
        text

      _ ->
        Logger.warning("receive_ollama_chat_response unknown chunk_line: #{chunk_line}")
        ""
    end
  end
end
