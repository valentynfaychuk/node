defmodule DB.API do
  def db_handle(db_opts, default_cf, merge_opts \\ %{}) do
    db = db_opts[:db]
    cf = db_opts[:cf]
    rtx = db_opts[:rtx]
    cond do
      !!rtx and !!cf -> Map.merge(%{rtx: rtx, cf: cf}, merge_opts)
      !!rtx -> Map.merge(%{rtx: rtx, cf: Map.fetch!(cf, default_cf)}, merge_opts)
      !!db and !!cf -> Map.merge(%{db: db, cf: cf}, merge_opts)
      !!db -> Map.merge(%{db: db, cf: Map.fetch!(cf, default_cf)}, merge_opts)
      true ->
        %{db: db, cf: cf} = :persistent_term.get({:rocksdb, Fabric})
        Map.merge(%{db: db, cf: Map.fetch!(cf, default_cf)}, merge_opts)
    end
  end
end
