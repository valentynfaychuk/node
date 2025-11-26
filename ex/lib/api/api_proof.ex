defmodule API.Proof do
  def proof_validators(entry_hash) do
    entry_hash = if byte_size(entry_hash) != 32, do: Base58.decode(entry_hash), else: entry_hash
    proof = Entry.proof_validators(entry_hash)
    %{
      value: Base58.encode(proof.value),
      key: proof.key,
      validators: Enum.map(proof.validators, & Base58.encode(&1)),
      proof: %{
        nodes: Enum.map(proof.proof.nodes, & %{direction: &1.direction, hash: Base58.encode(&1.hash)}),
        path: Base58.encode(proof.proof.path),
        path: Base58.encode(proof.proof.root),
        path: Base58.encode(proof.proof.hash),
      }
    }
  end
end
