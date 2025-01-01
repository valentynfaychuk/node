defmodule ETSExample do
  @table_name :my_table
  @ramdisk_path "/tmp/ramdisk/ets_data.tab"

  def create_ramdisk do
    ramdisk_size = "1G"

    # Create the RAM disk
    :os.cmd('sudo mkdir -p /tmp/ramdisk')
    :os.cmd('sudo mount -t tmpfs -o size=#{ramdisk_size} tmpfs /tmp/ramdisk')
  end

  def delete_ramdisk do
    # Unmount and clean up the RAM disk
    :os.cmd('sudo umount /tmp/ramdisk')
    :os.cmd('sudo rmdir /tmp/ramdisk')
  end

  def setup_table do
    # Create an ETS table
    :ets.new(@table_name, [:named_table, :set, :public])

    # Fill it with 1 million records of random data
    for _ <- 1..1_000_000 do
      key = :crypto.strong_rand_bytes(8) |> Base.encode16()
      value = %{
        random_key1: Enum.random(1..100000),
        random_key2: Enum.random(1..100000),
        random_key3: Enum.random(1..100000)
      }
      :ets.insert(@table_name, {key, value})
    end

    IO.puts("Inserted 1 million records into ETS table.")
  end

  def save_table do
    case :ets.tab2file(@table_name, '#{@ramdisk_path}') do
      :ok ->
        IO.puts("Table successfully saved to RAM disk.")
      {:error, reason} ->
        IO.puts("Failed to save table: #{reason}")
    end
  end

  def load_table do
    case :ets.file2tab('#{@ramdisk_path}') do
      :ok ->
        IO.puts("Table successfully loaded from RAM disk.")
      {:error, reason} ->
        IO.puts("Failed to load table: #{reason}")
    end
  end

  def run do
    create_ramdisk()
    setup_table()
    save_table()
    :ets.delete(@table_name) # Simulate clearing the ETS table
    load_table()

    IO.inspect(:ets.info(@table_name), label: "Table Info After Load")
  end
end

#ETSExample.run()
