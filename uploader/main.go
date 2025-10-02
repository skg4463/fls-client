package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/klauspost/reedsolomon"
)

const (
	DataShards   = 10
	ParityShards = 5
	ShardDir     = "./shards"
	ChainBinary  = "flstoraged"
	ChainID      = "flstorage"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Println("\033[32mUSAGE:\033[0m go run main.go [file-path] [tag] [from-address]")
		os.Exit(1)
	}
	filePath, tag, fromAddress := os.Args[1], os.Args[2], os.Args[3]

	fmt.Println("\033[32mTag style:\033[0m ROUND-USERaddr-CHAINID")
	fmt.Println("\033[34mCurrent Address: \033[0m", fromAddress)
	fmt.Println("\033[34mCurrent Tag: \033[0m", tag, "\n")

	fileData, err := os.ReadFile(filePath)
	if err != nil {
		fmt.Printf("Failed to read file: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("\033[33mFile read success:\033[0m %s (%d bytes)\n", filePath, len(fileData))

	originalHash := sha256.Sum256(fileData)
	originalHashStr := hex.EncodeToString(originalHash[:])
	fmt.Printf("\033[33mOriginal file hash:\033[0m %s\n", originalHashStr)

	enc, _ := reedsolomon.New(DataShards, ParityShards)
	shards, _ := enc.Split(fileData)
	enc.Encode(shards)

	shardHashes := make([]string, len(shards))
	os.MkdirAll(ShardDir, 0755)
	for i, shard := range shards {
		shardHash := sha256.Sum256(shard)
		shardHashStr := hex.EncodeToString(shardHash[:])
		shardHashes[i] = shardHashStr
		os.WriteFile(filepath.Join(ShardDir, shardHashStr), shard, 0644)
	}
	fmt.Printf("\033[33mTotal %d shards saved in '%s' directory.\033[0m\n", len(shards), ShardDir)

	// 모듈 이름을 "fedstoraging"으로, 명령어 이름을 "store-file"로 최종 수정.
	baseArgs := []string{"tx", "fedstoraging", "store-file", tag, originalHashStr}

	cmdArgs := append(baseArgs, shardHashes...)
	cmdArgs = append(cmdArgs,
		"--from", fromAddress,
		"--chain-id", ChainID, "-y",
		"--gas", "auto", "--gas-adjustment", "1.5",
	)
	fmt.Println("\n\033[34mCommand to execute:\033[0m", ChainBinary, cmdArgs)

	cmd := exec.Command(ChainBinary, cmdArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("\033[31mTransaction failed: %v\nOutput: %s\033[0m\n", err, string(output))
		os.Exit(1)
	}
	fmt.Println("\n\033[32mTransaction sent successfully!\033[0m\n", string(output))
}

