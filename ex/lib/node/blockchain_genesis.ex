defmodule BlockchainGenesis do
    @genesis_block "BSJQA99jZfhTkZBrLFP6YAVZz1ZaRHM9grJeXASoBRqB.5mVsb1xkaFaNMxeLKm7v7TZdnFKDR3sSF4M6QkE4dxs9NXL8dG1YqE8mtm1AVKkANPWWZfyCw91gEFFGmfqMPZ6o.{\"height\":0,\"mutation_root\":\"HioFbmF3i7HkMYKjbDWrPKWjiRLjaiqxwrjZtDVqgWVJ\",\"prev_hash\":\"\",\"prev_height\":-1,\"proof_of_history\":\"6hLd5tHs1bPyQD4xExjTip1ThuCNVj5KBhzss7SRDBo6\",\"trainer\":\"4MXG4qor6TRTX9Wuu9TEku7ivBtDooNL55vtu3HcvoQH\",\"transactions\":[],\"vdf\":{},\"vrf_signature\":\"33sq3yMgHwa74G5pqWjm8Dz7o56RNYoEh9Dnx8Daa2ADK8ktV336FHr63Dhx5zW47scVBMXFEUqke3rHHqZmRe4S\"}"

    def save() do
        block_packed = @genesis_block
        workdir = Application.fetch_env!(:ama, :work_folder)
        filepath_blockchain = Path.join(workdir, "blockchain/blockchain.flatkv")
        File.mkdir_p!(Path.join(workdir, "blockchain/"))
        File.write!(filepath_blockchain, <<byte_size(block_packed)::32-little, block_packed::binary>>)
    end

    def generate() do
        pk = Application.fetch_env!(:ama, :trainer_pk)
        sk = Application.fetch_env!(:ama, :trainer_sk)
        pk_b58 = Base58.encode(pk)

        entropy_seed = """
        aefeafeafeafefaefa
        """
        proof_of_history_raw = Blake3.hash(entropy_seed)
        vrf_signature_raw = Blake3.hash(proof_of_history_raw)
        vrf_signature_raw = (vrf_signature_raw <> vrf_signature_raw)

        env = %{block: %{height: 0, trainer: pk_b58}}
        {mutations, _} = BIC.Base.precall_block(env)
        block_encoded = %{
            height: 0,
            prev_height: -1,
            prev_hash: "",
            proof_of_history: proof_of_history_raw |> Base58.encode(),
            vrf_signature: vrf_signature_raw |> Base58.encode(),
            vdf: %{},
            mutation_root: Blake3.hash(mutations) |> Base58.encode(),
            transactions: [],
            trainer: pk_b58
        }
        |> JCS.serialize()

        hash = Blake3.hash(block_encoded)

        signature = :public_key.sign(hash, :ignored, {:ed_pri, :ed25519, pk, sk}, [])

        <<Base58.encode(hash)::binary,".",Base58.encode(signature)::binary,".",block_encoded::binary>>
    end
end
