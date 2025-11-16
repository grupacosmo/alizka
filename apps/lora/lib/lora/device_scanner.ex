defmodule Lora.DeviceScanner do
  @moduledoc """
  A GenServer responsible for periodically scanning for and starting
  workers for new LoRa devices.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    if Application.get_env(:lora, :scan_on_startup, true) do
      send(self(), :scan_for_devices)
    end

    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:scan_for_devices, state) do
    Logger.debug("Scanning for LoRa devices...")

    running_ports =
      Supervisor.which_children(Lora.Supervisor)
      |> Enum.flat_map(fn
        # Match only workers, whose IDs are port strings
        {port, _pid, :worker, [Lora.Worker]} when is_binary(port) -> [port]
        _ -> []
      end)

    Logger.debug("Running ports: #{inspect(running_ports)}")

    found_port_names = get_found_port_names()

    Logger.debug("Found ports: #{inspect(found_port_names)}")

    new_port_names = Enum.reject(found_port_names, &(&1 in running_ports))
    Logger.debug("New ports to be started: #{inspect(new_port_names)}")

    ports_to_remove = running_ports -- found_port_names

    for port <- ports_to_remove do
      Logger.info("Device #{port} disconnected, stopping worker.")

      case Supervisor.terminate_child(Lora.Supervisor, port) do
        :ok -> Logger.debug("Child #{port} deleted.")
        {:error, :running} -> Logger.debug("Child #{port} was already terminating.")
        other -> Logger.error("Could not delete child #{port}: #{inspect(other)}")
      end
    end

    for port <- new_port_names do
      Logger.info("Found new device: #{port}")
      Logger.debug("Attempting to start worker for #{port}...")

      child_spec = %{
        id: port,
        start: {Lora.Worker, :start_link, [{port, :rcv}]},
        restart: :transient
      }

      case Supervisor.start_child(Lora.Supervisor, child_spec) do
        {:ok, _pid} -> Logger.debug("Successfully started worker for #{port}")
        {:error, reason} -> Logger.error("Failed to start worker for #{port}: #{inspect(reason)}")
        other -> Logger.warning("start_child for #{port} returned: #{inspect(other)}")
      end
    end

    Process.send_after(self(), :scan_for_devices, 5000)
    {:noreply, state}
  end

  def get_found_port_names do
    uart_module = Application.get_env(:lora, :uart_module, Circuits.UART)

    uart_module.enumerate()
    |> Map.reject(&Enum.empty?(elem(&1, 1)))
    |> Map.keys()
  end
end
