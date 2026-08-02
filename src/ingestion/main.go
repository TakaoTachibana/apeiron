package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
	"nhooyr.io/websocket"
)

const (
	JetstreamURL = "wss://jetstream2.us-east.bsky.network/subscribe?wantedCollections=app.bsky.feed.post"

	ShmKey = 0x41504549
	ShmSize = 128 * 1024 * 1024
)

type SharedMemoryHeader struct {
	Magic uint32
	WriteIndex uint64
	ReadIndexR uint64
	ReadIndexJ uint64
}

type IngestionWorker struct {
	shmID int
	shmAddr []byte
	header *SharedMemoryHeader
}

func NewIngestionWorker() (*IngestionWorker, error) {
	shmID, err := unix.SysvShmGet(ShmKey, ShmSize, unix.IPC_CREAT|0666)
	if err != nil {
		return nil, fmt.Errorf("failed to allocate shared memory: %w", err)
	}

	shmAddr, err := unix.SysvShmAttach(shmID, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to attach shared memory: %w", err)
	}

	log.Printf("[Ingestion] Attached System V Shared Memory (ID: %d, Size: %d MB)", shmID, ShmSize/1024/1024)

	header := (*SharedMemoryHeader)(unsafe.Pointer(&shmAddr[0]))
	if header.Magic != 0x41504549 {
		header.Magic = 0x41504549
		atomic.StoreUint64(&header.WriteIndex, 64)
		log.Println("[Ingestion] Initialized new Shared Memory Header Block")
	}

	return &IngestionWorker {
		shmID: shmID,
		shmAddr: shmAddr,
		header: header,
	}, nil
}

func (w *IngestionWorker) WriteToRingBuffer(data []byte) {
	dataLen := uint32(len(data))
	if dataLen == 0 || dataLen > 65536 {
		return
	}

	totalLen := uint64(4 + dataLen)
	currPos := atomic.AddUint64(&w.header.WriteIndex, totalLen) - totalLen
	offset := 64 + (currPos % uint64(ShmSize-64))
	binary.LittleEndian.PutUint32(w.shmAddr[offset:offset+4], dataLen)
	copy(w.shmAddr[offset+4:offset+totalLen], data)
}

func (w *IngestionWorker) Close() {
	if err := unix.SysvShmDetach(w.shmAddr); err != nil {
		log.Printf("[Ingestion] Error detaching shared memory: %v", err)
	}
}

func main() {
	log.Println("=== A P E I R O N // Ingestion Microservice (Go) ===")

	worker, err := NewIngestionWorker()
	if err != nil {
		log.Fatalf("Fatal Error: %v", err)
	}
	defer worker.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	log.Printf("[Ingestion] Connecting to Jetstream: %s", JetstreamURL)
	conn, _, err := websocket.Dial(ctx, JetstreamURL, nil)
	if err != nil {
		log.Fatalf("[Ingestion] WebSocket Dial Error: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "shutting down")

	conn.SetReadLimit(2 * 1024 * 1024)

	log.Println("[Ingestion] Connected successfullly. Streaming posts to shared memory...")

	go func() {
		var packetCount uint64
		lastStat := time.Now()

		for {
			select {
			case <-ctx.Done():
				return
			default:
				_, message, err := conn.Read(ctx)
				if err != nil {
					log.Printf("[Ingestion] Read Error: %v", err)
					return
				}

				worker.WriteToRingBuffer(message)
				packetCount++

				if time.Since(lastStat) >= 5*time.Second{
					log.Printf("[Ingestion] Throughput: %d posts / 5s | Current Write Index: %d",
						packetCount, atomic.LoadUint64(&worker.header.WriteIndex))
					packetCount = 0
					lastStat = time.Now()
				}
			}
		}
	}()

	<-sigChan
	log.Println("\n[Ingestion] Shutting down gracefully...")
}


				



