ExUnit.start()

defmodule LoraTest.Helpers do
  def poll_for_child(supervisor, id, retries \\ 10)
  def poll_for_child(_supervisor, _id, 0), do: false

  def poll_for_child(supervisor, id, retries) do
    children = Supervisor.which_children(supervisor)

    if Enum.any?(children, fn {child_id, _, _, _} -> child_id == id end) do
      true
    else
      Process.sleep(100)
      poll_for_child(supervisor, id, retries - 1)
    end
  end

  def poll_for_child_removal(supervisor, id, retries \\ 10)
  def poll_for_child_removal(_supervisor, _id, 0), do: false

  def poll_for_child_removal(supervisor, id, retries) do
    children = Supervisor.which_children(supervisor)

    if Enum.any?(children, fn {child_id, _, _, _} -> child_id == id end) do
      Process.sleep(100)
      poll_for_child_removal(supervisor, id, retries - 1)
    else
      true
    end
  end

  def wait_for_files(files, timeout_ms \\ 1000) do
    step_interval = 50
    max_attempts = div(timeout_ms, step_interval)

    Enum.reduce_while(1..max_attempts, nil, fn _, _ ->
      if Enum.all?(files, &File.exists?/1) do
        {:halt, :ok}
      else
        Process.sleep(step_interval)
        {:cont, nil}
      end
    end)
  end
end

defmodule LoraTest.MockLora do
  alias Circuits.UART
  use GenServer
  require Logger
  import LoraTest.Helpers

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(ports: %{dev: dev_port, mock: mock_port}) do
    path = System.find_executable("socat") || exit("socat executable not found!")
    args = ["-d", "pty,rawer,echo=0,link=#{dev_port}", "pty,rawer,echo=0,link=#{mock_port}"]
    socat_port = Port.open({:spawn_executable, path}, [{:args, args}, :binary])
    Logger.debug("socat pseudo-tty's created!")

    if wait_for_files([dev_port, mock_port]) != :ok do
      exit("socat failed to create virtual devices.")
    end

    {:ok, uart_pid} = UART.start_link()

    case UART.open(uart_pid, mock_port, active: true) do
      :ok ->
        Logger.debug("Mock LoRa started on #{mock_port}")
        {:ok, %{uart_pid: uart_pid, socat_port: socat_port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({:circuits_uart, _uart, data}, state) do
    Logger.debug("Mock received: #{inspect(data)}")

    response =
      case data do
        "COMMAND1\r\n" -> "COMMAND1-RESPONSE\r\n"
        "COMMAND2\r\n" -> "COMMAND2-RESPONSE\r\n"
        "COMMAND3\r\n" -> "COMMAND3-RESPONSE\r\n"
        "COMMAND4\r\n" -> "COMMAND4-RESPONSE\r\n"
        _ -> "ERROR(-1)\r\n"
      end

    Logger.debug("response: #{response}")
    Circuits.UART.write(state.uart_pid, response)
    Circuits.UART.drain(state.uart_pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:send_counted_msgs, state) do
    Logger.debug("sending messages")
    send_messages(state, 10)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:send_cont_msgs, state) do
    send_messages(state, :cont)
  end

  def send_messages(_state, num_times) when num_times == 0, do: nil

  def send_messages(state, :cont) do
    send_message(state, "cont message\r\n")
    send_messages(state, :cont)
  end

  def send_messages(state, num_times) do
    send_message(state, "message no.#{num_times}\r\n")
    send_messages(state, num_times - 1)
  end

  def send_message(state, msg) do
    Circuits.UART.write(state.uart_pid, msg)
    Circuits.UART.drain(state.uart_pid)
    Logger.debug("sent msg: #{msg}")
  end

  @impl GenServer
  def terminate(_reason, %{uart_pid: uart_pid, socat_port: socat_port}) do
    Circuits.UART.close(uart_pid)
    Port.close(socat_port)
    Logger.debug("Mock LoRa and socat closed")
  end
end

defmodule LoraTest.MockUART do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok), do: {:ok, %{}}

  def handle_call(:enumerate, _from, state), do: {:reply, state, state}

  def handle_cast({:set_ports, ports}, _state) do
    {:noreply, ports}
  end

  # Public API
  def enumerate, do: GenServer.call(__MODULE__, :enumerate)
  def set_ports(ports), do: GenServer.cast(__MODULE__, {:set_ports, ports})
end
