defmodule Blockchain do
	@epoch_blocks 100_000

	def load_chain_on_init() do
		workdir = Application.fetch_env!(:ama, :work_folder)
        filepath_blockchain = Path.join(workdir, "blockchain/blockchain.flatkv")
        File.mkdir_p!(Path.join(workdir, "blockchain/"))
        if !File.exists?(filepath_blockchain) do
        	IO.puts "Generating genesis block.."
        	BlockchainGenesis.save()
        end
        BlockchainFlatKV.load_blockchain()
	end

	def produce_block() do
		if !is_in_slot(), do: throw %{error: :not_in_slot}

		block = Block.shell_from_head()

        {mutations, rev} = BIC.Base.precall_block(%{block: block})
		
		#TODO: fix me to a stepper of 1tx at a time
		txs = TXPool.take_for_block(block.height)
        {mutations, rev} = Enum.reduce(txs, {mutations, rev}, fn(tx_packed, {acc, rev})->
        	txu = TX.unwrap(tx_packed)
            {new_mut, new_rev} = BIC.Base.process_tx(%{block: block, txu: txu})

            :ets.insert(TXInChain, {txu.hash, txu})

            {<<acc::binary, new_mut::binary>>, rev ++ new_rev}
        end)

        mutation_root = Blake3.hash(mutations) |> Base58.encode()

        block = Map.merge(block, %{transactions: txs, mutation_root: mutation_root})
		block_encoded = JCS.serialize(block)

		hash_raw = Blake3.hash(block_encoded)
		hash = Base58.encode(hash_raw)

		pk_raw = Application.fetch_env!(:ama, :trainer_pk)
        sk_raw = Application.fetch_env!(:ama, :trainer_sk)
		signature_raw = :public_key.sign(hash_raw, :ignored, {:ed_pri, :ed25519, pk_raw, sk_raw}, [])
		signature = Base58.encode(signature_raw)

		block_packed = <<hash::binary,".",signature::binary,".",block_encoded::binary>>

        :ets.insert(Blockchain, {block.height, Block.unwrap(block_packed)})

        BlockchainFlatKV.save_block(block_packed)
        TXPool.purge_stale()

		block_packed
	end

	def insert_block(block_packed, loadingChain \\ false) do
		bu = Block.unwrap(block_packed)
		block = bu.block
		if loadingChain and block.height == 0 do
	        mutations = BIC.Base.precall_block(%{block: block})
		    IO.puts "📦 insert_genesis_block 0 #{bu.hash}"
			:ets.insert(Blockchain, {block.height, bu})
		else
			%{block: lb, hash: lb_hash} = Blockchain.block_last()
			
			trainer_for_slot = BIC.Trainer.slot(bu.block.proof_of_history |> Base58.decode())
			if block.trainer == trainer_for_slot and bu.block.prev_height == lb.height and bu.block.prev_hash == lb_hash do
	        	{mutations, rev} = BIC.Base.precall_block(%{block: block})
		        {mutations, rev} = Enum.reduce(block.transactions, {mutations, rev}, fn(tx_packed, {acc, rev})->
		        	txu = TX.unwrap(tx_packed)
		            {new_mut, new_rev} = BIC.Base.process_tx(%{block: block, txu: txu})

		            {<<acc::binary, new_mut::binary>>, rev ++ new_rev}
		        end)

		        #TODO: undo the block
		        mutation_root_correct = Base58.decode(block.mutation_root) == Blake3.hash(mutations)
		        cond do
		        	loadingChain and !mutation_root_correct -> 
		        		IO.inspect {:insert_block, :reject, :mutation_root_wrong, bu, lb, mutations}, limit: 11111111, printable_limit: :infinity
		        		:erlang.halt()
		        	!mutation_root_correct ->
		        		IO.inspect {:insert_block, :reject, :mutation_root_wrong, bu, lb, mutations}, limit: 11111111, printable_limit: :infinity
		        		rev = :lists.reverse(rev)
		        		Enum.each(rev, fn(mut)->
		        			BlockchainFlatKV.locally_apply_state_mutation(mut)
		        		end)

		        	mutation_root_correct ->
		    			#IO.puts "📦 insert_block #{bu.block.height} #{bu.hash}"

		        		Enum.each(block.transactions, fn(tx_packed)->
				        	txu = TX.unwrap(tx_packed)
				            :ets.insert(TXInChain, {txu.hash, txu})
		        		end)
			        	:ets.insert(Blockchain, {block.height, bu})

			        	if !loadingChain do
			        		BlockchainFlatKV.save_block(block_packed)
			        		TXPool.purge_stale()
			        	end
		        end
			end
		end
	end

	def is_in_slot() do
		%{block: lb} = Blockchain.block_last()
		next_slot = BIC.Trainer.slot(Blake3.hash(lb.proof_of_history |> Base58.decode()))
		my_pk = Application.fetch_env!(:ama, :trainer_pk_b58)
		my_pk == next_slot
	end

	def epoch() do
		%{block: %{height: height}} = block_last()
		trunc(height/100_000)
	end

	def height() do
		%{block: %{height: height}} = block_last()
		height
	end

	def block_last() do
		{_, [{_, map}]} = :ets.last_lookup(Blockchain)
		map
	end

    def block_by_height(height) do
        :ets.lookup_element(Blockchain, height, 2, nil)
    end

	def test() do
		{pk, sk} = :crypto.generate_key(:eddsa, :ed25519)
		packed_tx = Blockchain.build_transaction(sk, 0, "Trainer", "submit_sol", [123])
		TX.validate(packed_tx)
	end
end
