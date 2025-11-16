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
  @moduledoc """
  A GenServer mock for Circuits.UART that allows us to control the output of `enumerate/0`.
  """
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
  use ExUnit.Case, async: false
  @moduletag :device_scanner_logic

  setup do
    start_supervised!(LoraTest.MockUART)
    :ok
  end

  test "get_found_port_names/0 correctly filters and maps enumerated ports" do
    Application.put_env(:lora, :uart_module, LoraTest.MockUART)

    LoraTest.MockUART.set_ports(%{
      "ttyS0" => %{description: "real port"},
      "ttyFAKE" => %{description: "a fake serial port"},
      "ttyEMPTY" => %{}
    })

    found_ports = Lora.DeviceScanner.get_found_port_names()
    assert found_ports -- ["ttyS0", "ttyFAKE"] == []
    assert "ttyEMPTY" not in found_ports

    Application.delete_env(:lora, :uart_module)
  end
end

defmodule LoraTest.DeviceScannerTest do
  use ExUnit.Case, async: false
  import LoraTest.Helpers
  @moduletag :device_scanner_integration

  setup do
    Application.put_env(:lora, :scan_on_startup, false)
    Application.put_env(:lora, :uart_module, LoraTest.MockUART)

    start_supervised!(LoraTest.MockUART)

    ports = %{dev: "/tmp/lora-scanner-dev", mock: "/tmp/lora-scanner-mock"}
    start_supervised!({LoraTest.MockLora, ports: ports})

    spec = %{
      id: Lora.Supervisor,
      start:
        {Supervisor, :start_link,
         [[Lora.DeviceScanner], [strategy: :one_for_one, name: Lora.Supervisor]]}
    }

    start_supervised!(spec)

    on_exit(fn ->
      Application.delete_env(:lora, :scan_on_startup)
      Application.delete_env(:lora, :uart_module)
    end)

    {:ok, dev_port: ports.dev}
  end

  test "starts a worker for a newly discovered device", %{dev_port: dev_port} do
    assert Supervisor.which_children(Lora.Supervisor) |> length() == 1

    :ok = LoraTest.MockUART.set_ports(%{dev_port => %{description: "fake"}})

    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)

    assert poll_for_child(Lora.Supervisor, dev_port)

    children = Supervisor.which_children(Lora.Supervisor)
    assert length(children) == 2
    assert Enum.any?(children, fn {id, _, _, _} -> id == dev_port end)
  end
end
