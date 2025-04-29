defmodule LlmProvider do
  @moduledoc """
  Provides common functionality and configuration for LLM providers.
  """

  @doc """
  Returns the list of registered LLM provider modules.
  """
  def list_providers do
    [
      LlmProvider.Anthropic,
      LlmProvider.OpenAI,
      LlmProvider.Ollama
    ]
  end

  @doc """
  Returns a standardized system prompt for code generation.

  This prompt is designed to guide LLMs to generate clean, idiomatic Elixir code
  without explanations or markdown formatting.
  """
  def system_prompt do
    """
    You are an expert Elixir developer tasked with generating high-quality, idiomatic Elixir code.

    GUIDELINES:
    - Write clean, maintainable, and efficient Elixir code following community best practices
    - Follow Elixir code style (2-space indentation, snake_case for variables/functions) and functional style conventions
    - The code will be run in livebook elixir code cell
      - Last statement will be return value as result of the cell
      - Please execute the code right away by default

    RESPONSE FORMAT:
    - ONLY respond with code - no explanations, comments, or markdown formatting
    - Do NOT include ```elixir or ``` code blocks
    - Do NOT include any text before or after the code
    - The code should be ready to run without modification

    Example of correct response format:
    defmodule Example do
      def hello(name) do
        "Hello, \#{name}!"
      end
    end

    Example.hello("world")
    """
  end
end
