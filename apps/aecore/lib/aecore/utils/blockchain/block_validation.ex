defmodule Aecore.Utils.Blockchain.BlockValidation do

  alias Aecore.Keys.Worker, as: KeyManager
  alias Aecore.Pow.Hashcash
  alias Aecore.Structures.Block
  alias Aecore.Chain.ChainState

  @spec validate_block!(%Aecore.Structures.Block{},
                        %Aecore.Structures.Block{},
                        map()) :: {:error, term()} | :ok
  def validate_block!(new_block, previous_block, chain_state) do
    prev_block_header_hash = block_header_hash(previous_block.header)
    is_difficulty_target_met = Hashcash.verify(new_block.header)

    new_block_state = ChainState.calculate_block_state(new_block.txs)
    new_chain_state =
      ChainState.calculate_chain_state(new_block_state, chain_state)
    chain_state_hash = ChainState.calculate_chain_state_hash(new_chain_state)

    cond do
      new_block.header.prev_hash != prev_block_header_hash &&
        previous_block != Block.genesis_block ->
        throw({:error, "Incorrect previous hash"})
      previous_block.header.height + 1 != new_block.header.height ->
        throw({:error, "Incorrect height"})
      !is_difficulty_target_met ->
        throw({:error, "Header hash doesnt meet the difficulty target"})
      new_block.header.txs_hash != calculate_root_hash(new_block.txs) ->
        throw({:error, "Root hash of transactions does not match the one in header"})
      !(new_block |> validate_block_transactions |> Enum.all?) ->
        throw({:error, "One or more transactions not valid"})
      new_block.header.chain_state_hash != chain_state_hash ->
        throw({:error, "Chain state not valid"})
      true ->
        :ok
    end
  end

  @spec block_header_hash(%Aecore.Structures.Header{}) :: binary()
  def block_header_hash(header) do
    block_header_bin = :erlang.term_to_binary(header)
    :crypto.hash(:sha256, block_header_bin)
  end

  @spec validate_block_transactions(%Aecore.Structures.Block{}) :: list()
  def validate_block_transactions(block) do
    for transaction <- block.txs do
      KeyManager.verify(transaction.data,
                        transaction.signature,
                        transaction.data.from_acc)
    end
  end

  @spec filter_invalid_transactions(list()) :: list()
  def filter_invalid_transactions(txs) do
    Enum.filter(txs, fn(transaction) -> KeyManager.verify(transaction.data,
                      transaction.signature,
                      transaction.data.from_acc) end)
  end

  @spec calculate_root_hash(list()) :: binary()
  def calculate_root_hash(txs) do
    if(length(txs) == 0) do
      <<0::256>>
    else
      merkle_tree = for transaction <- txs do
        transaction_data_bin = :erlang.term_to_binary(transaction.data)
        {:crypto.hash(:sha256, transaction_data_bin), transaction_data_bin}
      end
      merkle_tree = merkle_tree |>
        List.foldl(:gb_merkle_trees.empty, fn(node, merkle_tree)
        -> :gb_merkle_trees.enter(elem(node,0), elem(node,1) , merkle_tree) end)
      merkle_tree |> :gb_merkle_trees.root_hash()
    end
  end

end
