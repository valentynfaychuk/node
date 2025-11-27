defmodule API.Proof do
  def proof_validators(entry_hash) do
    entry_hash = if byte_size(entry_hash) != 32, do: Base58.decode(entry_hash), else: entry_hash
    proof = Entry.proof_validators(entry_hash)
    %{
      value: Base58.encode(proof.value),
      key: proof.key,
      validators: Enum.map(proof.validators, & Base58.encode(&1)),
      proof: %{
        root: Base58.encode(proof.proof.root),
        path: Base58.encode(proof.proof.path),
        hash: Base58.encode(proof.proof.hash),
        nodes: Enum.map(proof.proof.nodes, & %{direction: &1.direction, hash: Base58.encode(&1.hash)}),
      }
    }
  end

  def proof_contractstate(key) do
    %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
    RDB.bintree_contractstate_root_prove(db, key)
  end
end
