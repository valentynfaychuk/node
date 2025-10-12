defmodule RDB do
  @moduledoc false

  use Rustler,
    otp_app: :ama,
    crate: "rdb"

  def test(), do: :erlang.nif_error(:nif_not_loaded)
  def open_transaction_db(_path, _cf_names), do: :erlang.nif_error(:nif_not_loaded)
  def property_value(_db, _key), do: :erlang.nif_error(:nif_not_loaded)
  def get(_db, _key), do: :erlang.nif_error(:nif_not_loaded)
  def put(_db, _key, _value), do: :erlang.nif_error(:nif_not_loaded)
  def delete(_db, _key), do: :erlang.nif_error(:nif_not_loaded)
end
