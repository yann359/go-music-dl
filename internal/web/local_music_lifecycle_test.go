package web

import (
	"testing"
	"time"
)

func TestCloseDBDrainsQueuedIndexTask(t *testing.T) {
	initCollectionDBForTest(t)
	started := make(chan struct{})
	release := make(chan struct{})
	closed := make(chan struct{})
	runLocalMusicIndexTask(func() {
		close(started)
		<-release
	})
	<-started
	go func() { CloseDB(); close(closed) }()
	select {
	case <-closed:
		close(release)
		t.Fatal("database closed before its queued index task finished")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("database did not close after the index task finished")
	}
}
