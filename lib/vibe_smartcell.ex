defmodule VibeSmartcell do
  use Kino.JS, assets_path: "lib/assets/vibe_smartcell"
  use Kino.JS.Live
  use Kino.SmartCell, name: "Vibe"

  require Logger

  @impl true
  def init(attrs, ctx) do
    source = attrs["source"] || ""
    prompt = attrs["prompt"] || ""
    model = attrs["model"] || ""

    ctx = assign(ctx,
      source: source,
      prompt: prompt,
      model: model,
      loading: false,
      models: []
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
      source: ctx.assigns.source
    }

    {:ok, payload, ctx}
  end

  @impl true
  def handle_info(:fetch_models, ctx) do
    # Get all available providers registered via `use LlmProvider`
    providers = LlmProvider.list_providers()

    # Collect models from all providers
    # Each provider is responsible for handling its own configuration
    models = providers
      |> Enum.flat_map(fn provider ->
        case provider.list_models() do  # Pass nil, let provider handle its own config
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
    if models == [] do
      LlmProvider.list_providers()
      |> show_error_with_config_example("To use this smartcell, you need to configure at least one provider.", self())
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
    show_error_with_config_example(provider, "#{provider.name} not configured", self())

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
      ctx = assign(ctx, loading: true)
      broadcast_event(ctx, "generation_started", %{})

      # Start the generation process in a separate task
      pid = self()
      Task.start(fn ->
        model_id = ctx.assigns.model

        # Find the provider for this model
        provider = find_provider_for_model(model_id, ctx.assigns.models)

        if provider do
          provider.generate_code(ctx.assigns.prompt, model_id, pid)
        else
          send(pid, {:generation_complete, "# Error: Selected model not found or provider not available"})
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

  defp show_error_with_config_example(providers, message, pid) do
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
        #     # #{provider.name} configuration:
        #{config_example_lines}
        #     # #{provider.config_additional_info}
        #
        """
      end)
    end)
    |> Enum.join()
    |> String.trim()
    |> then(fn providers_config_example ->
      """
      # #{message}
      #
      # Add to your notebook setup:
      #
      # ```elixir
      # Application.put_all_env(
      #   vibe_smartcell: [
      #{providers_config_example}
      #   ]
      # )
      # ```
      #
      # About Livebook secrets env: https://hexdocs.pm/livebook/shared_secrets.html
      """
    end)
    |> then(fn message ->
      send(pid, {
        :generation_complete,
        message,
      })
    end)
  end
end
