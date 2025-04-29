defmodule VibeChatSmartcell do
  use Kino.JS, assets_path: "lib/assets/vibe_chat_smartcell"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Vibe Chat"

  alias VibeSmartcell.ConfigExampleHelper

  require Logger

  @impl true
  def init(attrs, ctx) do
    messages = attrs["messages"] || []
    model = attrs["model"] || ""

    ctx =
      assign(ctx,
        messages: messages,
        model: model,
        loading: false,
        models: [],
        error_message: nil
      )

    # Fetch models asynchronously
    pid = self()

    Task.start(fn ->
      send(pid, :fetch_models)
    end)

    {:ok, ctx}
  end

  @impl true
  def handle_connect(ctx) do
    payload = %{
      messages: ctx.assigns.messages,
      model: ctx.assigns.model,
      models: ctx.assigns.models,
      loading: ctx.assigns.loading,
      error_message: ctx.assigns.error_message
    }

    {:ok, payload, ctx}
  end

  @impl true
  def handle_info(:fetch_models, ctx) do
    # Get all available providers registered via `use LlmProvider`
    providers = LlmProvider.list_providers()

    # Collect models from all providers
    # Each provider is responsible for handling its own configuration
    models =
      providers
      |> Enum.flat_map(fn provider ->
        # Pass nil, let provider handle its own config
        case provider.list_models() do
          models when is_list(models) ->
            # Add provider information to each model
            Enum.map(models, fn model ->
              model
              |> Map.put(:provider, provider)
              |> Map.put(:name, "#{provider.name()} - #{model.name}")
            end)

          {:error, _reason} ->
            []
        end
      end)

    ctx = assign(ctx, models: models)
    broadcast_event(ctx, "update_models", %{models: models})

    # If no models were found, send a message to show configuration hints
    ctx =
      if models == [] do
        providers = LlmProvider.list_providers()

        show_error_with_config_example(
          ctx,
          providers,
          "To use this smartcell, you need to configure at least one provider."
        )
      else
        ctx
      end

    {:noreply, ctx}
  end

  @impl true
  def handle_info({:response_chunk, chunk}, ctx) do
    broadcast_event(ctx, "response_chunk", %{chunk: chunk})
    {:noreply, ctx}
  end

  @impl true
  def handle_info({:chat_complete, response}, ctx) do
    # Add the assistant's response to messages
    updated_messages = ctx.assigns.messages ++ [%{role: "assistant", content: response}]

    ctx =
      assign(ctx,
        messages: updated_messages,
        loading: false
      )

    broadcast_event(ctx, "chat_complete", %{
      messages: updated_messages
    })

    {:noreply, ctx}
  end

  @impl true
  def handle_info({:provider_not_configured, provider}, ctx) do
    ctx = show_error_with_config_example(ctx, provider, "#{provider.name} not configured")
    {:noreply, ctx}
  end

  @impl true
  def handle_event("update_model", %{"model" => model}, ctx) do
    {:noreply, assign(ctx, model: model)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, ctx) do
    if ctx.assigns.loading do
      {:noreply, ctx}
    else
      # Add the user message to the messages list
      updated_messages = ctx.assigns.messages ++ [%{role: "user", content: message}]
      # Clear any previous error message
      ctx = assign(ctx, messages: updated_messages, loading: true, error_message: nil)

      broadcast_event(ctx, "message_sent", %{messages: updated_messages})
      broadcast_event(ctx, "update_error", %{error_message: nil})

      # Start the chat process in a separate task
      pid = self()

      Task.start(fn ->
        model_id = ctx.assigns.model

        # Find the provider for this model
        provider = find_provider_for_model(model_id, ctx.assigns.models)

        if provider do
          # Convert messages to the format expected by the provider
          formatted_messages =
            Enum.map(updated_messages, fn %{role: role, content: content} ->
              %{role: role, content: content}
            end)

          provider.generate_chat_response(formatted_messages, model_id, pid)
        else
          error_message = "Error: Selected model not found or provider not available"
          ctx = assign(ctx, error_message: error_message, loading: false)
          broadcast_event(ctx, "update_error", %{error_message: error_message})
          # Also broadcast loading state change
          broadcast_event(ctx, "chat_complete", %{messages: updated_messages})
        end
      end)

      {:noreply, ctx}
    end
  end

  @impl true
  def handle_event("clear_chat", _params, ctx) do
    # Clear messages and any error message
    ctx = assign(ctx, messages: [], error_message: nil)
    broadcast_event(ctx, "chat_cleared", %{})
    broadcast_event(ctx, "update_error", %{error_message: nil})

    {:noreply, ctx}
  end

  @impl true
  def to_attrs(ctx) do
    %{
      "messages" => ctx.assigns.messages,
      "model" => ctx.assigns.model
    }
  end

  @impl true
  def to_source(_attrs) do
    ":noop"
  end

  # Find the provider for a specific model ID
  defp find_provider_for_model(model_id, models) do
    Enum.find_value(models, fn
      %{id: ^model_id, provider: provider} -> provider
      _ -> nil
    end)
  end

  defp show_error_with_config_example(ctx, providers, message) do
    error_message = ConfigExampleHelper.generate(providers, message)
    broadcast_event(ctx, "update_error", %{error_message: error_message})
    broadcast_event(ctx, "chat_complete", %{messages: ctx.assigns.messages})
    assign(ctx, error_message: error_message, loading: false)
  end
end
