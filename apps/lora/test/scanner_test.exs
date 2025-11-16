defmodule LoraTest.DeviceScannerLogicTest do
  use ExUnit.Case, async: false

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

  setup_all do
    Application.put_env(:lora, :scan_on_startup, false)
    Application.put_env(:lora, :uart_module, LoraTest.MockUART)

    ports = %{dev: "/tmp/lora-scanner-dev", mock: "/tmp/lora-scanner-mock"}
    {:ok, mock_pid} = LoraTest.MockLora.start_link(ports: ports)

    on_exit(fn ->
      GenServer.stop(mock_pid)
      Application.delete_env(:lora, :scan_on_startup)
      Application.delete_env(:lora, :uart_module)
    end)

    {:ok, dev_port: ports.dev}
  end

  setup do
    start_supervised!(LoraTest.MockUART)
    spec = %{id: Lora.Supervisor, start: {Lora.Application, :start, [nil, nil]}}
    start_supervised!(spec)
    :ok
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

  test "scanner avoids starting duplicate workers", %{dev_port: dev_port} do
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 1

    child_spec = %{
      id: dev_port,
      start: {Lora.Worker, :start_link, [{dev_port, :rcv}]},
      restart: :transient
    }

    {:ok, _} = Supervisor.start_child(Lora.Supervisor, child_spec)
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 2

    :ok = LoraTest.MockUART.set_ports(%{dev_port => %{description: "fake"}})
    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)

    Process.sleep(100)
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 2
  end

  test "scanner removes a worker after disconnect", %{dev_port: dev_port} do
    :ok = LoraTest.MockUART.set_ports(%{dev_port => %{description: "fake"}})

    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)

    assert poll_for_child(Lora.Supervisor, dev_port)
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 2

    LoraTest.MockUART.set_ports(%{})

    # Get the worker's PID before it's terminated
    [{^dev_port, worker_pid, _, _}] =
      Enum.filter(Supervisor.which_children(Lora.Supervisor), fn {id, _, _, _} ->
        id == dev_port
      end)

    mref = Process.monitor(worker_pid)
    send(scanner, :scan_for_devices)

    assert_receive {:DOWN, ^mref, :process, ^worker_pid, _}, 5000
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 1
  end

  test "scanner handles worker start failure" do
    LoraTest.MockUART.set_ports(%{})
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 1

    LoraTest.MockUART.set_ports(%{"/tmp/non_existent_port" => %{description: "fake"}})

    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)
    Process.sleep(100)
    assert Supervisor.count_children(Lora.Supervisor) |> Map.get(:active) == 1
  end
end
