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
	DataShards   = 10
	ParityShards = 5
	ShardDir     = "../uploader/shards"
	ChainBinary  = "flstoraged"
)

// 사이드체인 쿼리 결과에 맞는 JSON 구조체
type StoredFile struct {
	OriginalHash string   `json:"original_hash"`
	Tag          string   `json:"tag"`
	Creator      string   `json:"creator"`
	ShardHashes  []string `json:"shard_hashes"`
}

type QueryResponse struct {
	StoredFile StoredFile `json:"stored_file"`
}

func main() {
	if len(os.Args) != 3 {
		fmt.Println("\033[32mUSAGE:\033[0m go run main.go [original-hash] [output-path]")
		os.Exit(1)
	}
	originalHash, outputPath := os.Args[1], os.Args[2]

	// 모듈 이름을 "fedstoraging"으로 수정
	cmdArgs := []string{"query", "fedstoraging", "show-stored-file", originalHash, "--output", "json"}

	cmd := exec.Command(ChainBinary, cmdArgs...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("\033[31mQuery failed: %v\nOutput: %s\033[0m\n", err, string(output))
		os.Exit(1)
	}

	var resp QueryResponse
	if err := json.Unmarshal(output, &resp); err != nil {
		fmt.Printf("\033[31mJSON parsing failed: %v\033[0m\n", err)
		fmt.Println("Original JSON response:", string(output))
		os.Exit(1)
	}

	// --- 요청하신 색깔 출력 적용 ---
	fmt.Println("On-chain metadata query successful.")
	fmt.Println("\033[32mTag:\033[0m", resp.StoredFile.Tag, "\033[34m(Tag style: ROUND-USERaddr-CHAINID)\033[0m")
	fmt.Println("\033[32mCreator:\033[0m", resp.StoredFile.Creator)
	fmt.Println("\033[32mOriginal Hash:\033[0m", originalHash)
	fmt.Println("\033[32mShard Count:\033[0m", len(resp.StoredFile.ShardHashes))
	fmt.Println()
	// --- 적용 끝 ---

	if len(resp.StoredFile.ShardHashes) == 0 {
		fmt.Println("\033[31mError: No shard hashes found in the queried data. Please check the query result.\033[0m")
		os.Exit(1)
	}

	shards := make([][]byte, len(resp.StoredFile.ShardHashes))
	foundCount := 0
	for i, shardHash := range resp.StoredFile.ShardHashes {
		data, err := os.ReadFile(filepath.Join(ShardDir, shardHash))
		if err != nil {
			shards[i] = nil
			continue
		}
		shards[i] = data
		foundCount++
	}
	if foundCount < DataShards {
		fmt.Printf("\033[31mNot enough data shards found (required: %d, found: %d)\033[0m\n", DataShards, foundCount)
		os.Exit(1)
	}
	fmt.Printf("\033[33m%d shards found. Starting file reconstruction.\033[0m\n", foundCount)

	enc, _ := reedsolomon.New(DataShards, ParityShards)
	err = enc.Reconstruct(shards)
	if err != nil {
		fmt.Printf("\033[31mReconstruction failed: %v\033[0m\n", err)
		os.Exit(1)
	}

	var buf bytes.Buffer
	err = enc.Join(&buf, shards, len(shards[0])*DataShards)
	if err != nil {
		fmt.Printf("\033[31mFailed to join shards: %v\033[0m\n", err)
		os.Exit(1)
	}

	finalHash := sha256.Sum256(buf.Bytes())
	if hex.EncodeToString(finalHash[:]) != originalHash {
		fmt.Println("\033[31mFile integrity verification failed!\033[0m")
		os.Exit(1)
	}
	fmt.Println("\033[32mFile integrity verified.\033[0m")

	err = os.WriteFile(outputPath, buf.Bytes(), 0644)
	if err != nil {
		fmt.Printf("\033[31mFailed to write restored file: %v\033[0m\n", err)
		os.Exit(1)
	}
	fmt.Printf("\033[32mFile successfully restored and saved to %s.\033[0m\n", outputPath)
}

