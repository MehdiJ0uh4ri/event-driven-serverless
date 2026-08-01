// Cold-start benchmark subject -- Go on the provided.al2023 runtime.
//
// Mirrors the Node and Python subjects: no third-party imports beyond the
// Lambda runtime interface client (which Go cannot avoid, since provided.al2023
// has no built-in runtime), the same shape of package-level init work, and the
// same JSON log line so tools/coldstart_benchmark.py parses all three
// identically.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
)

var (
	initStartedAt  = time.Now()
	runtimeName    = "go" + goVersionSuffix()
	config         benchConfig
	initDurationMs float64
	invocations    int
)

type benchConfig struct {
	Region   string `json:"region"`
	MemoryMB int    `json:"memoryMb"`
	Version  string `json:"version"`
	Nonce    string `json:"nonce"`
}

type request struct {
	Ping any `json:"ping"`
}

type response struct {
	Runtime         string  `json:"runtime"`
	ColdStart       bool    `json:"coldStart"`
	ModuleInitMs    float64 `json:"moduleInitMs"`
	MemoryMB        int     `json:"memoryMb"`
	InvocationCount int     `json:"invocationCount"`
	Echo            any     `json:"echo"`
}

func goVersionSuffix() string {
	// Reported for the record; the exact toolchain is pinned in go.mod.
	return "1.22"
}

func init() {
	mem, _ := strconv.Atoi(os.Getenv("AWS_LAMBDA_FUNCTION_MEMORY_SIZE"))
	nonce := os.Getenv("BENCH_NONCE")
	if nonce == "" {
		nonce = "none"
	}
	config = benchConfig{
		Region:   os.Getenv("AWS_REGION"),
		MemoryMB: mem,
		Version:  os.Getenv("AWS_LAMBDA_FUNCTION_VERSION"),
		Nonce:    nonce,
	}
	initDurationMs = float64(time.Since(initStartedAt).Microseconds()) / 1000.0
}

func handler(ctx context.Context, req request) (response, error) {
	invocations++
	isColdStart := invocations == 1

	line, _ := json.Marshal(map[string]any{
		"level":        "INFO",
		"message":      "bench_invocation",
		"runtime":      runtimeName,
		"coldStart":    isColdStart,
		"moduleInitMs": initDurationMs,
		"memoryMb":     config.MemoryMB,
		"nonce":        config.Nonce,
	})
	fmt.Println(string(line))

	return response{
		Runtime:         runtimeName,
		ColdStart:       isColdStart,
		ModuleInitMs:    initDurationMs,
		MemoryMB:        config.MemoryMB,
		InvocationCount: invocations,
		Echo:            req.Ping,
	}, nil
}

func main() {
	lambda.Start(handler)
}
