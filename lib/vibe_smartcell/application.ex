defmodule VibeSmartcell.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Kino.SmartCell.register(VibeCoderSmartcell)
    Kino.SmartCell.register(VibeChatSmartcell)
    children = []
    opts = [strategy: :one_for_one, name: HandsontableKinoSmartcell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
