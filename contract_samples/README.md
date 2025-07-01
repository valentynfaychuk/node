### Local contract testing

Run the node OFFLINE=true ./amadeusd

```elixir
pk = Application.fetch_env!(:ama, :trainer_pk)
sk = Application.fetch_env!(:ama, :trainer_sk)

Offline.deploy(Path.join([pwd(), "deposit.wasm"]))

Offline.add_balance(BIC.Coin.to_flat(1000), pk)

Offline.call(sk, pk, "deposit", [], "AMA", "1000")
Offline.call(sk, pk, "withdraw", ["AMA", "100"])
Offline.call(sk, pk, "balance", ["AMA"])
```
