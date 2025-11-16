defmodule Lora.Application do
  require Logger
  use Application

  def start(_, _) do
    Logger.debug("Starting Lora application")

    children = [
      Lora.DeviceScanner
    ]

    opts = [strategy: :one_for_one, name: Lora.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def get_data do
    Supervisor.which_children(Lora.Supervisor)
    |> Enum.map(fn {id, pid, _type, _modules} -> {id, pid} end)
    |> Enum.reject(&match?({Lora.DeviceScanner, _}, &1))
    |> Task.async_stream(&Lora.Worker.get_msgs/1, timeout: 5000)
    |> Enum.flat_map(fn {:ok, result} -> result end)
  end
end
