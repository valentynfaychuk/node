defmodule BIC.CoinSymbolReserved do
    @reserved_list %{
        "AMA"=> true,
    }

    def is_free(symbol, caller) do
        upcase_symbol = String.upcase(symbol)
        in_reserve = @reserved_list[upcase_symbol]
        cond do
            in_reserve == caller -> true
            String.starts_with?(upcase_symbol, "AMA") -> false
            !in_reserve -> true
            true -> false
        end
    end
end
