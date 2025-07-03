### Deploy AssemblyScript WASM Contract
  
Install nodejs-22-lts + assemblyscript
  
```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
npm install --global assemblyscript
```
  
Build the deposit contract setting memory base to 65536 just in-case (not required)
Enable importMemory to allow calling imports
  
```bash
asc 1_deposit.ts --target release --importMemory --memoryBase 65536 --outFile deposit.wasm
```
  
Check bytecode is valid by validating it via RPC
```bash
curl -X POST -H "Content-Type: application/octet-stream" --data-binary @deposit.wasm https://nodes.amadeus.bot/api/contract/validate_bytecode
```
  
Set your WORKFOLDER envvar to your location of your `sk` aka `base58 encoded 64bytes seed`
because the default is `~/.cache/amadeusd`
```bash
./amadeusd deploytx "~/deposit.wasm" | sed '1,4d' | curl -X POST -H "Content-Type: application/octet-stream" https://nodes.amadeus.bot/api/tx/submit
```
OR  
```bash
touch /home/user/key1/sk
WORKFOLDER=/home/user/key1/ ./amadeusd deploytx "/home/user/project/node/contract_samples/assemblyscript/deposit.wasm" | sed '1,4d' | curl -X POST -H "Content-Type: application/octet-stream" --data-binary @- https://nodes.amadeus.bot/api/tx/submit
```
  
Call it
```bash
export PK=777d6Z9WMM5WvKRaEuJH5abEBSMuuoQzotND82j5QpmxWBNfyusgQu46ZyHy9kgYT8
WORKFOLDER=/home/user/key1/ ./amadeusd buildtx ${PK} deposit [] AMA 1000 | sed '1,4d' | curl -X POST -H "Content-Type: application/octet-stream" --data-binary @- https://nodes.amadeus.bot/api/tx/submit
WORKFOLDER=/home/user/key1/ ./amadeusd buildtx ${PK} withdraw ["AMA","100"] | sed '1,4d' | curl -X POST -H "Content-Type: application/octet-stream" --data-binary @- https://nodes.amadeus.bot/api/tx/submit
```

View it
```bash
export PK=777d6Z9WMM5WvKRaEuJH5abEBSMuuoQzotND82j5QpmxWBNfyusgQu46ZyHy9kgYT8
curl -X GET -H "Content-Type: application/octet-stream" https://nodes.amadeus.bot/api/contract/get/${PK}/vault:${PK}:AMA
```
