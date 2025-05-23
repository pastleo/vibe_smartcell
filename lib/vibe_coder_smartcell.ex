defmodule VibeCoderSmartcell do
  use Kino.JS, assets_path: "lib/assets/vibe_coder_smartcell"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Vibe Coder"

  alias VibeSmartcell.ConfigExampleHelper

  require Logger

  @impl true
  def init(attrs, ctx) do
    source = attrs["source"] || ""
    prompt = attrs["prompt"] || ""
    model = attrs["model"] || ""

    ctx =
      assign(ctx,
        source: source,
        prompt: prompt,
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
      prompt: ctx.assigns.prompt,
      model: ctx.assigns.model,
      models: ctx.assigns.models,
      loading: ctx.assigns.loading,
      source: ctx.assigns.source,
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
  def handle_info({:code_chunk, chunk}, ctx) do
    broadcast_event(ctx, "code_chunk", %{chunk: chunk})
    {:noreply, ctx}
  end

  @impl true
  def handle_info({:generation_complete, source}, ctx) do
    ctx = assign(ctx, source: source, loading: false)
    broadcast_event(ctx, "generation_complete", %{source: source})

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
  def handle_event("update_prompt", %{"prompt" => prompt}, ctx) do
    {:noreply, assign(ctx, prompt: prompt)}
  end

  @impl true
  def handle_event("update_source", %{"source" => source}, ctx) do
    {:noreply, assign(ctx, source: source)}
  end

  @impl true
  def handle_event("generate", _params, ctx) do
    if ctx.assigns.loading do
      {:noreply, ctx}
    else
      # Clear any previous error message
      ctx = assign(ctx, loading: true, error_message: nil)
      broadcast_event(ctx, "generation_started", %{})
      broadcast_event(ctx, "update_error", %{error_message: nil})

      # Start the generation process in a separate task
      pid = self()

      Task.start(fn ->
        model_id = ctx.assigns.model

        # Find the provider for this model
        provider = find_provider_for_model(model_id, ctx.assigns.models)

        if provider do
          provider.generate_code(ctx.assigns.prompt, model_id, pid)
        else
          error_message = "# Error: Selected model not found or provider not available"
          ctx = assign(ctx, error_message: error_message, loading: false)
          broadcast_event(ctx, "update_error", %{error_message: error_message})
          # Also broadcast loading state change
          broadcast_event(ctx, "generation_complete", %{source: ctx.assigns.source})
        end
      end)

      {:noreply, ctx}
    end
  end

  @impl true
  def to_attrs(ctx) do
    %{
      "source" => ctx.assigns.source,
      "prompt" => ctx.assigns.prompt,
      "model" => ctx.assigns.model
    }
  end

  @impl true
  def to_source(attrs) do
    attrs["source"]
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
    broadcast_event(ctx, "generation_complete", %{source: ctx.assigns.source})
    assign(ctx, error_message: error_message, loading: false)
  end
end
