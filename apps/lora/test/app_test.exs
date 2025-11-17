defmodule LoraTest.AppTest do
  require Logger
  use ExUnit.Case, async: false
  import LoraTest.Helpers

  setup do
    dev_path = "/tmp/lora-scanner-dev-#{System.unique_integer([:positive])}"
    mock_path = "/tmp/lora-scanner-mock-#{System.unique_integer([:positive])}"
    ports = %{dev: dev_path, mock: mock_path}
    {:ok, mock_pid} = LoraTest.MockLora.start_link(ports: ports)
    Application.put_env(:lora, :uart_module, LoraTest.MockUART)
    start_supervised!(LoraTest.MockUART)
    spec = %{id: Lora.Supervisor, start: {Lora.Application, :start, [nil, nil]}}
    start_supervised!(spec)

    on_exit(fn ->
      if Process.alive?(mock_pid), do: GenServer.stop(mock_pid)
      File.rm(ports.dev)
      File.rm(ports.mock)
      Application.delete_env(:lora, :uart_module)
    end)

    {:ok, dev_port: ports.dev}
  end

  test "E2E happy path", %{dev_port: dev_port} do
    :ok = LoraTest.MockUART.set_ports(%{dev_port => %{description: "fake"}})

    scanner = Process.whereis(Lora.DeviceScanner)
    assert scanner
    send(scanner, :scan_for_devices)

    assert poll_for_child(Lora.Supervisor, dev_port)

    assert Lora.Application.get_data() |> Enum.sort() == [
             "COMMAND1-RESPONSE",
             "COMMAND2-RESPONSE",
             "COMMAND3-RESPONSE",
             "COMMAND4-RESPONSE"
           ]
  end
end
