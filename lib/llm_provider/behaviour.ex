defmodule LlmProvider.Behaviour do
  @moduledoc """
  Behaviour that defines the interface for LLM providers.

  This behaviour specifies the callbacks that any LLM provider implementation
  must implement to be compatible with the VibeSmartcell system.
  """

  @doc """
  Name of the LlmProvider
  """
  @callback name() :: String.t()

  @doc """
  Lists available models from the provider.

  Returns a list of maps in the form:
  [ %{id: "model-id", name: "Model Name"}, ... ]
  """
  @callback list_models() :: [%{id: String.t(), name: String.t()}] | {:error, String.t()}

  @doc """
  Generates code based on the given prompt using the specified model.

  The function should stream the response to the given process ID by sending messages:
  - {:code_chunk, chunk} for each chunk of generated code
  - {:generation_complete, full_response} when generation is complete
  - {:provider_not_configured} if the API key is missing or invalid
  """
  @callback generate_code(prompt :: String.t(), model :: String.t(), pid :: pid()) :: :ok

  @doc """
  Returns configuration example for this provider.
  """
  @callback example_config() :: %{atom() => String.t()}

  @doc """
  Any additional information or instructions for config
  """
  @callback config_additional_info() :: String.t()
end
