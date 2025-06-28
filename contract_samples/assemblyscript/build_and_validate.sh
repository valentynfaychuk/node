#curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
#npm install --global assemblyscript

asc 0_counter.ts --target release --importMemory --memoryBase 65536 --outFile counter.wasm
asc 1_deposit.ts --target release --importMemory --memoryBase 65536 --outFile deposit.wasm
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @counter.wasm https://nodes.amadeus.bot/api/contract/validate_bytecode
echo ""
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @deposit.wasm https://nodes.amadeus.bot/api/contract/validate_bytecode
echo ""
