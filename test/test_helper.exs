ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Matrx.Repo, :manual)
{:ok, _} = Registry.start_link(keys: :unique, name: Matrx.Support.FakeAPI.Registry)
