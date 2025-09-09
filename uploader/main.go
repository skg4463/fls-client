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
	DataShards   = 10; ParityShards = 5
	ShardDir     = "./shards"
	ChainBinary  = "flstoraged"
	ChainID      = "flstorage"
)

func main() {
	if len(os.Args) != 4 { fmt.Println("사용법: go run main.go [파일-경로] [태그] [보내는-사람-주소]"); os.Exit(1) }
	filePath, tag, fromAddress := os.Args[1], os.Args[2], os.Args[3]
	
	fmt.Println("\033[32mUSAGE:\033[0m go run main.go [file-path] [tag] [from-address]")
	fmt.Println("\033[32mTag style:\033[0m ROUND-USERaddr-CHAINID")
	fmt.Println("\033[34mCurrent Address: \033[0m", fromAddress)
	fmt.Println("\033[34mCurrent Tag: \033[0m", tag, "\n")

	fileData, _ := os.ReadFile(filePath)
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
	fmt.Printf("\033[33mFile save success:\033[0m A total of %d Shards have been saved to the '%s' directory.\n", len(shards), ShardDir)

	baseArgs := []string{"tx", "storage", "create-stored-file", originalHashStr, tag}
	cmdArgs := append(baseArgs, shardHashes...)
	cmdArgs = append(cmdArgs,
		"--from", fromAddress,
		"--chain-id", ChainID, "-y",
		"--gas", "auto", "--gas-adjustment", "1.5",
	)
	fmt.Println("Executing command:", ChainBinary, cmdArgs)

	cmd := exec.Command(ChainBinary, cmdArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil { fmt.Printf("Transaction submission failed: %v\nOutput: %s\n", err, string(output)); os.Exit(1) }
	fmt.Println("\nTransaction submitted successfully!\n", string(output))
}