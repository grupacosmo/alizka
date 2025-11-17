import Config
IO.puts("load TEST env")

# Configure the DeviceScanner to use a mock UART module during tests.
config :lora,
  uart_module: LoraTest.MockUART,
  scan_on_startup: false

config :lora,
  common_setup_commands: ["COMMAND1", "COMMAND2", "COMMAND3"],
  rcv: ["COMMAND4"],
  snd: [~s(AT+TEST=TXLRSTR="Send mode set")],
  port_config: [
    speed: 115_200,
    active: false,
    framing: {Circuits.UART.Framing.Line, separator: "\r\n"}
  ]

config :logger,
  level: :error,
  compile_time_purge_matching: [
    [level_lower_than: :warning]
  ]
