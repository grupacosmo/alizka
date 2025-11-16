defmodule LoraTest.MockLora do
  alias Circuits.UART
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  defp wait_for_files(files, timeout_ms \\ 1000) do
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

defmodule LoraTest.WorkerTest do
  use ExUnit.Case, async: false

  setup do
    # Define the port names for a single mock device
    ports = %{
      dev: "/tmp/lora-dev",
      mock: "/tmp/lora-mock"
    }

    {:ok, mock_pid} = LoraTest.MockLora.start_link(ports: ports)

    on_exit(fn ->
      if Process.alive?(mock_pid) do
        GenServer.stop(mock_pid)
      end

      File.rm(ports.dev)
      File.rm(ports.mock)
    end)

    {:ok, %{dev_port: ports.dev, mock_port: ports.mock, mock_pid: mock_pid}}
  end

  test "Setup communications test", %{dev_port: dev_port} do
    {:ok, pid} = Lora.Worker.start_link({dev_port, :rcv})
    Process.sleep(1)

    assert Lora.Worker.get_msgs(pid) == [
             "COMMAND4-RESPONSE",
             "COMMAND3-RESPONSE",
             "COMMAND2-RESPONSE",
             "COMMAND1-RESPONSE"
           ]
  end

  test "counted messages test", %{dev_port: dev_port, mock_pid: mock_pid} do
    {:ok, pid} = Lora.Worker.start_link({dev_port, :rcv})
    Process.sleep(1)
    Lora.Worker.get_msgs(pid)

    GenServer.cast(mock_pid, :send_counted_msgs)
    Process.sleep(1)

    assert Lora.Worker.get_msgs(pid) == [
             "message no.10",
             "message no.9",
             "message no.8",
             "message no.7",
             "message no.6",
             "message no.5",
             "message no.4",
             "message no.3",
             "message no.2",
             "message no.1"
           ]
  end

  test "continuous messages test", %{dev_port: dev_port, mock_pid: mock_pid} do
    {:ok, pid} = Lora.Worker.start_link({dev_port, :rcv})
    Process.sleep(1)
    Lora.Worker.get_msgs(pid)

    GenServer.cast(mock_pid, :send_cont_msgs)
    Process.sleep(1)
    assert Lora.Worker.get_msgs(pid) != []
    Process.sleep(1)
    assert Lora.Worker.get_msgs(pid) != []
  end
end

defmodule LoraTest.DeviceScannerLogicTest do
  use ExUnit.Case, async: true
  @moduletag :device_scanner_logic

  defmodule MockUART do
    def enumerate do
      %{ 
        "ttyS0" => %{description: "real port"},
        "ttyFAKE" => %{description: "a fake serial port"},
        "ttyEMPTY" => %{}
      }
    end
  end

  test "get_found_port_names/0 correctly filters and maps enumerated ports" do
    # Configure the scanner to use the mock UART for this test
    Application.put_env(:lora, :uart_module, MockUART)

    found_ports = Lora.DeviceScanner.get_found_port_names()
    assert found_ports -- ["ttyS0", "ttyFAKE"] == []
    assert "ttyEMPTY" not in found_ports

    # Clean up the application environment
    Application.delete_env(:lora, :uart_module)
  end
end

defmodule LoraTest.DeviceScannerTest do
  use ExUnit.Case, async: false
  @moduletag :device_scanner_integration

  # This is a new, separate mock for this test module.
  defmodule MockUART do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    def init(:ok), do: {:ok, %{}}

    def handle_call(:enumerate, _from, state), do: {:reply, state, state}

    def handle_call({:set_ports, ports}, _from, _state) do
      {:reply, :ok, ports}
    end

    # Public API
    def enumerate, do: GenServer.call(__MODULE__, :enumerate)
    def set_ports(ports), do: GenServer.call(__MODULE__, {:set_ports, ports})
  end

  # This GenServer manages the socat process for the test
  defmodule SocatManager do
    use GenServer

    def start_link(ports) do
      GenServer.start_link(__MODULE__, ports, name: __MODULE__)
    end

    def init(ports) do
      path = System.find_executable("socat") || exit("socat executable not found!")
      args = ["-d", "pty,rawer,echo=0,link=#{ports.dev}", "pty,rawer,echo=0,link=#{ports.mock}"]
      socat_port = Port.open({:spawn_executable, path}, [{:args, args}, :binary])
      :ok = wait_for_files([ports.dev, ports.mock])
      {:ok, %{socat_port: socat_port, ports: ports}}
    end

    def terminate(_reason, state) do
      Port.close(state.socat_port)
      File.rm(state.ports.dev)
      File.rm(state.ports.mock)
      :ok
    end

    defp wait_for_files(files, timeout_ms \\ 1000) do
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

  setup do
    # Configure the environment for the test *before* starting any processes
    Application.put_env(:lora, :scan_on_startup, false)
    Application.put_env(:lora, :uart_module, MockUART)

    # Start the mock UART server
    start_supervised!(MockUART)

    # Create a pseudo-terminal for the worker to connect to
    ports = %{dev: "/tmp/lora-scanner-dev", mock: "/tmp/lora-scanner-mock"}
    start_supervised!({SocatManager, ports})

    # Start a supervisor with the DeviceScanner under the test's supervision tree.
    spec = %{
      id: Lora.Supervisor,
      start:
        {Supervisor, :start_link,
         [[Lora.DeviceScanner], [strategy: :one_for_one, name: Lora.Supervisor]]}
    }
    start_supervised!(spec)

    on_exit(fn ->
      # Clean up application environment
      Application.delete_env(:lora, :scan_on_startup)
      Application.delete_env(:lora, :uart_module)
    end)

    {:ok, dev_port: ports.dev}
  end

  test "starts a worker for a newly discovered device", %{dev_port: dev_port} do
    # Initially, only the DeviceScanner should be running
    assert Supervisor.which_children(Lora.Supervisor) |> length() == 1

    # "Connect" a new device by updating the mock's state synchronously
    :ok = LoraTest.DeviceScannerTest.MockUART.set_ports(%{dev_port => %{description: "fake"}})

    # Manually trigger a scan
    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)

    # Poll until the child is started or we time out
    assert poll_for_child(dev_port)

    # Final assertions
    children = Supervisor.which_children(Lora.Supervisor)
    assert length(children) == 2
    assert Enum.any?(children, fn {id, _, _, _} -> id == dev_port end)
  end

  defp poll_for_child(id, retries \\ 10)
  defp poll_for_child(_id, 0), do: false
  defp poll_for_child(id, retries) do
    children = Supervisor.which_children(Lora.Supervisor)
    if Enum.any?(children, fn {child_id, _, _, _} -> child_id == id end) do
      true
    else
      Process.sleep(100)
      poll_for_child(id, retries - 1)
    end
  end
end