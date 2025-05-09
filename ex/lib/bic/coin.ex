defmodule BIC.Coin do
    import ConsensusKV

    @decimals 9
    @burn_address :binary.copy(<<0>>, 48)

    def to_flat(coins) when is_integer(coins) do
        coins * 1_000_000_000
    end

    def to_cents(coins) when is_integer(coins) do
        coins *    10_000_000
    end

    def to_tenthousandth(coins) when is_integer(coins) do
        coins *       100_000
    end

    def from_flat(coins) do
        Float.round(coins / 1_000_000_000, 9)
    end

    def burn_address() do
        @burn_address
    end

    def burn_balance(symbol \\ "AMA") do
        balance(@burn_address, symbol)
    end

    def balance(pubkey, symbol \\ "AMA") do
        kv_get("bic:coin:balance:#{pubkey}:#{symbol}", %{to_integer: true}) || 0
    end

    def call(:transfer, env, [receiver, amount]), do: call(:transfer, env, [receiver, amount, "AMA"])
    def call(:transfer, env, [receiver, amount, symbol]) do
        {receiver, amount, symbol} = if receiver == "AMA" do {amount, symbol, receiver} else {receiver, amount, symbol} end

        if byte_size(receiver) != 48, do: throw(%{error: :invalid_receiver_pk})
        if !BlsEx.validate_public_key(receiver) and receiver != @burn_address, do: throw(%{error: :invalid_receiver_pk})
        amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end
        if !is_integer(amount), do: throw(%{error: :invalid_amount})
        if amount <= 0, do: throw(%{error: :invalid_amount})
        if amount > balance(env.account_caller, symbol), do: throw(%{error: :insufficient_funds})

        #Not necessary as balance check would fail
        #if symbol != "AMA" and !kv_get("bic:coin:totalSupply:#{symbol}"), do: throw(%{error: :abort, reason: :symbol_doesnt_exist})

        if kv_get("bic:coin:pausable:#{symbol}") == "true" and kv_get("bic:coin:paused:#{symbol}") == "true", do: throw(%{error: :paused})

        kv_increment("bic:coin:balance:#{env.account_caller}:#{symbol}", -amount)
        kv_increment("bic:coin:balance:#{receiver}:#{symbol}", amount)
    end

    def call(:create_and_mint, env, [symbol_original, amount, mintable, pausable]) do
        if !is_binary(symbol_original), do: throw(%{error: :invalid_symbol})
        symbol = Util.alphanumeric(symbol_original)
        if symbol != symbol_original, do: throw(%{error: :invalid_symbol})
        if byte_size(symbol) >= 1, do: throw(%{error: :symbol_too_short})
        if byte_size(symbol) <= 32, do: throw(%{error: :symbol_too_long})

        amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end
        if !is_integer(amount), do: throw(%{error: :invalid_amount})
        if amount <= 0, do: throw(%{error: :invalid_amount})

        if !BIC.CoinSymbolReserved.is_free(symbol, env.account_caller), do: throw(%{error: :symbol_reserved})
        if kv_get("bic:coin:totalSupply:#{symbol}"), do: throw(%{error: :symbol_exists})

        kv_increment("bic:coin:balance:#{env.account_caller}:#{symbol}", amount)
        kv_increment("bic:coin:totalSupply:#{symbol}", amount)

        kv_put("bic:coin:permission:#{symbol}", [env.account_caller], %{term: true})
        mintable == "true" && kv_put("bic:coin:mintable:#{symbol}", "true")
        pausable == "true" && kv_put("bic:coin:pausable:#{symbol}", "true")
    end

    def call(:mint, env, [symbol, amount]) do
        if !is_binary(symbol), do: throw(%{error: :invalid_symbol})

        amount = if is_binary(amount) do :erlang.binary_to_integer(amount) else amount end
        if !is_integer(amount), do: throw(%{error: :invalid_amount})
        if amount <= 0, do: throw(%{error: :invalid_amount})

        if !kv_get("bic:coin:totalSupply:#{symbol}"), do: throw(%{error: :symbol_doesnt_exist})
        
        admins = kv_get("bic:coin:permission:#{symbol}", %{term: true})
        if env.account_caller not in admins, do: throw(%{error: :no_permissions})

        if kv_get("bic:coin:mintable:#{symbol}") != "true", do: throw(%{error: :not_mintable})
        if kv_get("bic:coin:pausable:#{symbol}") == "true" and kv_get("bic:coin:paused:#{symbol}") == "true", do: throw(%{error: :paused})

        kv_increment("bic:coin:balance:#{env.account_caller}:#{symbol}", amount)
        kv_increment("bic:coin:totalSupply:#{symbol}", amount)
    end

    def call(:pause, env, [symbol, direction]) do
        if !is_binary(symbol), do: throw(%{error: :invalid_symbol})
        if direction not in ["true", "false"], do: throw(%{error: :invalid_direction})

        if !kv_get("bic:coin:totalSupply:#{symbol}"), do: throw(%{error: :symbol_doesnt_exist})
        
        admins = kv_get("bic:coin:permission:#{symbol}", %{term: true})
        if env.account_caller not in admins, do: throw(%{error: :no_permissions})

        if kv_get("bic:coin:pausable:#{symbol}") != "true", do: throw(%{error: :not_pausable})

        kv_put("bic:coin:paused:#{symbol}", direction)
    end
end