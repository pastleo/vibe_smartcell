defmodule LlmProvider do
  @moduledoc """
  """

  @doc """
  Returns the list of registered LLM provider modules
  """
  def list_providers do
    [
      LlmProvider.Anthropic
    ]
  end
end
