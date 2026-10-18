defmodule Matrx.Megolm.InboundSession do
  use Matrx.Megolm.Session, table: "megolm_inbound_sessions", inbound: true
end
