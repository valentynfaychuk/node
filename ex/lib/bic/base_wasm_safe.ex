defmodule BIC.Base.WASM.Safe do
    import ConsensusKV

    def safe_call(parent_pid, mapenv, wasmbytes, function, args) do
        case WasmerEx.call(parent_pid, mapenv, wasmbytes, function, args) do
          {:error, reason} -> send(parent_pid, {:result, {reason, [], 0, nil}})
          :ok -> nil
        end
    end

    def spawn(mapenv, wasmbytes, function, args) do
        parent_pid = self()
        :erlang.spawn(BIC.Base.WASM.Safe, :safe_call, [parent_pid, mapenv, wasmbytes, function, args])
    end
end
