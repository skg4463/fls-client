# fls-client
This repository is for submitting the original Round learning results of flstorage and uploading and downloading originalHash and tags.


## Environment
Ignite CLI version:             v29.3.1-dev

Ignite CLI source hash:         845a1a8886b8a098ed56372bab45ddee5caea526

Ignite CLI config version:      v1

Cosmos SDK version:             v0.53.3

Your go version:                go version go1.24.7 linux/amd64

## Get started

```
ignite chain serve

계정 및 키 확인
flstoraged keys list

업로드 확인된 alice 키 삽입 [fls-client - uploader]
go run main.go ../model_round_1_client_1.bin "1-[aliceAddr]-flstorage" [aliceAddr]

결과의 originalHash를 통해 query 
flstoraged query storage show-stored-file [originalHash]

txhash를 통해 블록 생성 확인 
flstoraged query tx [txHash]

block height를 통한 블록 확인
flstoraged query block --type=height 30248

downloader를 통해 originalHash를 인자로 복원 [fls-client - downloader]
go run main.go [originalHash] ../restored_round_weight.bin

checksum 비교를 통해 복원 확인
sha256sum model_round_1_client_1.bin restored_round_weight.bin
```