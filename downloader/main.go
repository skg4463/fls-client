package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/klauspost/reedsolomon"
)

const (
	DataShards   = 10; ParityShards = 5
	ShardDir     = "../uploader/shards"
	ChainBinary  = "flstoraged"
)

type StoredFile struct { OriginalHash, Tag, Creator string; ShardHashes []string `json:"shard_hashes"` }
// --- 이 부분의 JSON 태그를 "StoredFile"에서 "storedFile"로 수정 --- comel 법칙
type QueryResponse struct { StoredFile StoredFile `json:"stored_file"` }

func main() {
	if len(os.Args) != 3 { fmt.Println("사용법: go run main.go [원본-해시] [저장-경로]"); os.Exit(1) }
	originalHash, outputPath := os.Args[1], os.Args[2]

	cmdArgs := []string{"query", "storage", "show-stored-file", originalHash, "--output", "json"}
	cmd := exec.Command(ChainBinary, cmdArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil { fmt.Printf("쿼리 실패: %v\n출력: %s\n", err, string(output)); os.Exit(1) }

	var resp QueryResponse
	json.Unmarshal(output, &resp)
	fmt.Println("On-chain metadata query successful.")
	fmt.Println("\033[32mTag:\033[0m:", resp.StoredFile.Tag, "\033[34mTag style:\033[0m ROUND-USERaddr-CHAINID")
	fmt.Println("\033[32mCreator:\033[0m", resp.StoredFile.Creator)
	fmt.Println("\033[32mOriginal Hash:\033[0m", originalHash)
	fmt.Println("\033[32mShard Count:\033[0m", len(resp.StoredFile.ShardHashes))
	fmt.Println()

	shards := make([][]byte, len(resp.StoredFile.ShardHashes))
	foundCount := 0
	for i, shardHash := range resp.StoredFile.ShardHashes {
		data, err := os.ReadFile(filepath.Join(ShardDir, shardHash));
		if err != nil { shards[i] = nil; continue }
		shards[i] = data; foundCount++
	}
	if foundCount < DataShards { fmt.Printf("데이터 조각 부족\n"); os.Exit(1) }
	
	fmt.Printf("%d shards found. Starting file reconstruction.\n", foundCount)

	enc, _ := reedsolomon.New(DataShards, ParityShards)
	enc.Reconstruct(shards)
	var buf bytes.Buffer
	enc.Join(&buf, shards, len(shards[0])*DataShards)
	finalHash := sha256.Sum256(buf.Bytes())

	if hex.EncodeToString(finalHash[:]) != originalHash { fmt.Println("File integrity check failed!"); os.Exit(1) }
	fmt.Println("File integrity check passed.")

	os.WriteFile(outputPath, buf.Bytes(), 0644)
	fmt.Printf("File has been successfully restored and saved to %s.\n", outputPath)
}