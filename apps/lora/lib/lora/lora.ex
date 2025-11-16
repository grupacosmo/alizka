defmodule Lora.Worker do
  @moduledoc """
  TODO: add and check UART disconnect recovery
  """
  require Logger
  alias Circuits.UART
  use GenServer

  def start_link({port, :rcv}),
    do: GenServer.start_link(__MODULE__, {port, :rcv})

  def start_link({port, :snd}),
    do: GenServer.start_link(__MODULE__, {port, :snd})

  @impl GenServer
  def init({port, mode}) do
    Logger.debug("starting worker on port: #{port}")
    {:ok, config} = Application.fetch_env(:lora, :port_config)

    with {:ok, pid} <- UART.start_link(),
         :ok <- UART.open(pid, port, config) do
      Logger.debug("port #{port} opened correctly")
      {:ok, %{port: port, mode: mode, pid: pid}, {:continue, :init}}
    else
      err ->
        Logger.error("couldn't open port #{port}: #{inspect(err)}")
        {:stop, err}
    end
  end

  @impl GenServer
  def handle_continue(:init, %{port: port, mode: mode, pid: pid} = state) do
    Logger.debug("starting secondary init")
    {:ok, commands} = Application.fetch_env(:lora, :common_setup_commands)
    {:ok, mode_commands} = Application.fetch_env(:lora, mode)
    commands = commands ++ mode_commands
    setup_responses = run_commands(commands, pid, port)
    :ok = UART.configure(pid, active: true)
    state = Map.put(state, :messages, setup_responses)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:circuits_uart, port, {:error, :eio}}, state) do
    Logger.error("Port #{port} disconnected or errored, shutting down worker.")
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:circuits_uart, _, msg}, %{messages: messages} = state) do
    Logger.info("New message #{msg}")
    messages = [msg | messages]
    new_state = Map.put(state, :messages, messages)
    {:noreply, new_state}
  end

  @impl GenServer
  def terminate(_reason, %{pid: pid}) do
    :ok = UART.close(pid)
    Logger.debug("Closed UART port and terminated worker.")
    :shutdown
  end

  @impl GenServer
  def handle_call(:get_msgs, _from, %{messages: messages} = state) do
    ordered_messagess = Enum.reverse(messages)

    new_state = Map.put(state, :messages, [])
    {:reply, ordered_messagess, new_state}
  end

  def get_msgs(pid) do
    GenServer.call(pid, :get_msgs)
  end

  def run_commands([hd | rst], pid, port) do
    :ok = UART.write(pid, hd)
    UART.flush(pid, :transmit)
    {:ok, resp} = UART.read(pid)
    Logger.debug("#{port} : #{resp}")
    [resp | run_commands(rst, pid, port)]
  end

  def run_commands([], _pid, port) do
    Logger.debug("#{port} : All commands finished")
    []
  end
end
