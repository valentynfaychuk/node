defmodule API.Contract do
    def get(key, parse_type \\ nil) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        opts = %{db: db, cf: cf.contractstate}
        opts = if parse_type != nil do Map.put(opts, parse_type, true) else opts end
        RocksDB.get(key, opts)
    end

    def get_prefix(prefix, parse_type \\ nil) do
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        opts = %{db: db, cf: cf.contractstate}
        opts = if parse_type != nil do Map.put(opts, parse_type, true) else opts end
        RocksDB.get_prefix(prefix, opts)
    end

    def view(account, function, args) do
    end

    def validate_bytecode(bytecode) do
        task = Task.async(fn -> BIC.Contract.validate(bytecode) end)
        try do
          err = %{error: _} = Task.await(task, 100)
          err
        catch
          :exit, {:timeout, _} ->
            Task.shutdown(task, :brutal_kill)
            %{error: :system, reason: :timeout}
        end
    end

    def richlist() do
      key = "account:#{:binary.copy(<<0>>, 48)}:balance:AMA"
      {acc, count} = richlist_1(key, {[], 0})
      acc = acc
      |> Enum.filter(& &1.symbol == "AMA")
      |> Enum.sort_by(& &1.flat, :desc)
      {acc, count}
    end
    def richlist_1(key, {acc, count}) do
      %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
      seek = RocksDB.seek_next(key, %{db: db, cf: cf.contractstate})
      case seek do
        {<<"account:", pk::384, ":balance:AMA">>, value} ->
          key = <<"account:", (pk+1)::384, ":balance:AMA">>
          flat = :erlang.binary_to_integer(value)
          entry = %{pk: Base58.encode(<<pk::384>>), symbol: "AMA", flat: flat, float: trunc(BIC.Coin.from_flat(flat))}
          richlist_1(key, {acc ++ [entry], count + 1})
        {<<"account:", pk::384, _::binary>>, _} ->
          key = <<"account:", pk::384, ":balance:AMA">>
          richlist_1(key, {acc, count})
        {_, _} -> {acc, count}
      end
    end

    def total_burned() do
      API.Wallet.balance(BIC.Coin.burn_address())
    end
end
