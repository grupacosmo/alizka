defmodule LoraTest.WorkerTest do
  require Logger
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

  test "worker gracefully shuts down after uart disconnect", %{
    dev_port: dev_port
  } do
    {:ok, pid} = Lora.Worker.start_link({dev_port, :rcv})
    assert Process.alive?(pid)
    send(pid, {:circuits_uart, "0", {:error, :eio}})
    Process.sleep(100)
    assert !Process.alive?(pid)
  end

  test "graceful shutdown when port can't be open" do
    # Trap exits to prevent the test process from crashing
    Process.flag(:trap_exit, true)
    assert {:error, _} = Lora.Worker.start_link({"/tmp/non_existent_port", :rcv})
    Process.flag(:trap_exit, false)
  end
end
