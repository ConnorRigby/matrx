defmodule Matrx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Matrx.PubSub},
      Matrx.Repo,
      {Task.Supervisor, name: Matrx.TaskSupervisor},
      {Registry, keys: :unique, name: Matrx.RoomRegistry},
      Matrx.RoomSupervisor
      # Starts a worker by calling: Matrx.Worker.start_link(arg)
      # {Matrx.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Matrx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
