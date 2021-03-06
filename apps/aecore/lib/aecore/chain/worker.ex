defmodule Aecore.Chain.Worker do
  @moduledoc """
  Module for working with chain
  """

  require Logger

  alias Aecore.Structures.Block
  alias Aecore.Chain.ChainState
  alias Aecore.Txs.Pool.Worker, as: Pool
  alias Aecore.Utils.Blockchain.BlockValidation
  alias Aecore.Peers.Worker, as: Peers

  use GenServer

  def start_link(_args) do
    GenServer.start_link(__MODULE__, {}, name: __MODULE__)
  end

  def init(_) do
    genesis_block_hash = BlockValidation.block_header_hash(Block.genesis_block().header)

    genesis_block_map = %{genesis_block_hash => Block.genesis_block()}
    genesis_chain_state = ChainState.calculate_block_state(Block.genesis_block().txs)
    latest_block_chain_state = %{genesis_block_hash => genesis_chain_state}

    initial_state = {genesis_block_map, latest_block_chain_state}

    {:ok, initial_state}
  end

  @spec latest_block() :: %Block{}
  def latest_block() do
    latest_block_hashes = get_latest_block_chain_state() |> Map.keys()
    latest_block_hash = case(length(latest_block_hashes)) do
      1 -> List.first(latest_block_hashes)
      _ -> throw({:error, "multiple or none latest block hashes"})
    end

    get_block(latest_block_hash)
  end

  @spec get_latest_block_chain_state() :: tuple()
  def get_latest_block_chain_state() do
    GenServer.call(__MODULE__, :get_latest_block_chain_state)
  end

  @spec get_block_by_hex_hash(term()) :: %Block{}
  def get_block_by_hex_hash(hash) do
    GenServer.call(__MODULE__, {:get_block_by_hex_hash, hash})
  end

  @spec get_block(term()) :: %Block{}
  def get_block(hash) do
    GenServer.call(__MODULE__, {:get_block, hash})
  end

  @spec get_blocks(binary(), integer()) :: :ok
  def get_blocks(start_block_hash, size) do
    Enum.reverse(get_blocks([], start_block_hash, size))
  end

  @spec add_block(%Block{}) :: :ok
  def add_block(%Block{} = block) do
    GenServer.call(__MODULE__, {:add_block, block})
  end

  @spec chain_state(binary()) :: map()
  def chain_state(latest_block_hash) do
    GenServer.call(__MODULE__, {:chain_state, latest_block_hash})
  end

  def handle_call(:get_latest_block_chain_state, _from, state) do
    {_, latest_block_chain_state} = state
    {:reply, latest_block_chain_state, state}
  end

  def handle_call({:get_block, block_hash}, _from, state) do
    {block_map, _} = state
    block = block_map[block_hash]

    if(block != nil) do
      {:reply, block, state}
    else
      {:reply, {:error, "Block not found"}, state}
    end
  end

  def handle_call({:get_block_by_hex_hash, hash}, _from, state) do
    {chain, _} = state
    case(Enum.find(chain, fn{block_hash, _block} ->
      block_hash |> Base.encode16() == hash end)) do
      {_, block} ->
        {:reply, block, state}
      nil ->
        {:reply, {:error, "Block not found"}, state}
    end
  end

  def handle_call({:add_block, %Block{} = block}, _from, state) do
    {chain, chain_state} = state
    prev_block_chain_state = chain_state[block.header.prev_hash]
    new_block_state = ChainState.calculate_block_state(block.txs)
    new_chain_state = ChainState.calculate_chain_state(new_block_state, prev_block_chain_state)

    try do
      BlockValidation.validate_block!(block, chain[block.header.prev_hash], new_chain_state)

      Enum.each(block.txs, fn(tx) -> Pool.remove_transaction(tx) end)

      {block_map, latest_block_chain_state} = state
      block_hash = BlockValidation.block_header_hash(block.header)
      updated_block_map = Map.put(block_map, block_hash, block)
      has_prev_block = Map.has_key?(latest_block_chain_state, block.header.prev_hash)

      {deleted_latest_chain_state, prev_chain_state} = case has_prev_block do
        true ->
          prev_chain_state = Map.get(latest_block_chain_state, block.header.prev_hash)
          {Map.delete(latest_block_chain_state, block.header.prev_hash), prev_chain_state}
        false ->
          {latest_block_chain_state, %{}}
      end

      new_block_state = ChainState.calculate_block_state(block.txs)
      new_chain_state = ChainState.calculate_chain_state(new_block_state, prev_chain_state)

      updated_latest_block_chainstate = Map.put(deleted_latest_chain_state, block_hash, new_chain_state)

      total_tokens = ChainState.calculate_total_tokens(new_chain_state)

      Logger.info(fn ->
        "Added block ##{block.header.height} with hash #{block.header
        |> BlockValidation.block_header_hash()
        |> Base.encode16()}, total tokens: #{total_tokens}"
      end)

      ## Block was validated, now we can send it to other peers
      Peers.broadcast_to_all({:new_block, block})

      {:reply, :ok, {updated_block_map, updated_latest_block_chainstate}}
    catch
      {:error, message} ->
        Logger.error(fn ->
          "Failed to add block: #{message}"
        end)
      {:reply, :error, state}
    end
  end

  def handle_call({:chain_state, latest_block_hash}, _from, state) do
    {_, chain_state} = state
    {:reply, chain_state[latest_block_hash], state}
  end

  def chain_state() do
    latest_block = latest_block()
    latest_block_hash = BlockValidation.block_header_hash(latest_block.header)
    chain_state(latest_block_hash)
  end

  def all_blocks() do
    latest_block_obj = latest_block()
    latest_block_hash = BlockValidation.block_header_hash(latest_block_obj.header)
    get_blocks(latest_block_hash, latest_block_obj.header.height)
  end

  defp get_blocks(blocks_acc, next_block_hash, size) do
    cond do
      size > 0 ->
        case(GenServer.call(__MODULE__, {:get_block, next_block_hash})) do
          {:error, _} -> blocks_acc
          block ->
            updated_block_acc = [block | blocks_acc]
            prev_block_hash = block.header.prev_hash
            next_size = size - 1

            get_blocks(updated_block_acc, prev_block_hash, next_size)
        end
      true ->
        blocks_acc
    end
  end
end
