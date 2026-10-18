defmodule Matrx.Megolm.OutboundSession do
  use Matrx.Megolm.Session, table: "megolm_outbound_sessions", counted: true
end
