import Config
IO.puts("load DEV env")

config :lora,
  common_setup_commands: ["AT", "AT+MODE=TEST", "AT+TEST=RFCFG,868,SF8,250,12,15,14,ON,OFF,OFF"],
  rcv: ["AT+TEST=RXLRPKT"],
  snd: [~s(AT+TEST=TXLRSTR="Send mode set")],
  port_config: [
    speed: 115_200,
    active: false,
    framing: {Circuits.UART.Framing.Line, separator: "\r\n"}
  ]

config :logger,
  level: :debug
