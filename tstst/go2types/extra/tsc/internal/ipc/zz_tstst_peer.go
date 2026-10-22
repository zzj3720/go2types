package ipc

import (
	"bytes"
	"context"
	"io"
	"strconv"
)

// TststPeer is an in-process connection to a handler without goroutines: a
// message the client writes is handled as soon as it is complete, on the
// client's own stack, and the reply waits in a buffer for the client's next
// read. It stands in for net.Pipe plus a goroutine running an AsyncConn
// (contentmappertest's spawner), which needs two goroutines blocking on each
// other. The client has to read replies inline (a SyncConn), since a reader
// goroutine would block on the empty buffer.
type TststPeer struct {
	pend   []byte       // client bytes not yet forming a whole message
	in     bytes.Buffer // one whole message for the server to read
	out    bytes.Buffer // replies for the client
	server *SyncConn
	closed bool
}

var _ io.ReadWriteCloser = (*TststPeer)(nil)

// tststPeers counts the peers made: the content mapper host compares the count
// around a Spawn to tell an in-process mapper from a process, also when a test
// spawner wraps the connection it returns
var tststPeers int

// TststPeerCount is the number of peers made so far.
func TststPeerCount() int { return tststPeers }

// NewTststPeer serves handler the way an AsyncConn on the other end of a pipe would.
func NewTststPeer(handler Handler) *TststPeer {
	tststPeers++
	p := &TststPeer{}
	side := tststServerSide{p}
	p.server = NewSyncConn(side, NewJSONRPCProtocol(side), handler)
	return p
}

type tststServerSide struct{ p *TststPeer }

func (s tststServerSide) Read(b []byte) (int, error) {
	if s.p.in.Len() == 0 {
		return 0, io.EOF
	}
	return s.p.in.Read(b)
}

func (s tststServerSide) Write(b []byte) (int, error) { return s.p.out.Write(b) }

func (s tststServerSide) Close() error { return nil }

func (p *TststPeer) Read(b []byte) (int, error) {
	if p.out.Len() == 0 {
		if p.closed {
			return 0, io.EOF
		}
		return 0, io.ErrUnexpectedEOF
	}
	return p.out.Read(b)
}

func (p *TststPeer) Write(b []byte) (int, error) {
	if p.closed {
		return 0, io.ErrClosedPipe
	}
	p.pend = append(p.pend, b...)
	for {
		n := tststFrameLen(p.pend)
		if n == 0 {
			return len(b), nil
		}
		p.in.Write(p.pend[:n])
		p.pend = p.pend[n:]
		if err := p.serveOne(); err != nil {
			return len(b), err
		}
	}
}

func (p *TststPeer) Close() error {
	p.closed = true
	return nil
}

// serveOne handles the message in p.in as SyncConn.Run's loop would.
func (p *TststPeer) serveOne() error {
	c := p.server
	msg, err := c.protocol.ReadMessage()
	if err != nil {
		return err
	}
	ctx := context.Background()
	if msg.IsRequest() {
		return c.handleRequest(ctx, msg)
	}
	if msg.IsNotification() {
		c.handleNotification(ctx, msg)
	}
	return nil
}

// tststFrameLen is the length of the first whole Content-Length framed message
// in b, or 0 when b does not hold one yet.
func tststFrameLen(b []byte) int {
	end := bytes.Index(b, []byte("\r\n\r\n"))
	if end < 0 {
		return 0
	}
	length := -1
	for _, line := range bytes.Split(b[:end], []byte("\r\n")) {
		key, value, ok := bytes.Cut(line, []byte(":"))
		if ok && bytes.Equal(key, []byte("Content-Length")) {
			n, err := strconv.Atoi(string(bytes.TrimSpace(value)))
			if err == nil {
				length = n
			}
		}
	}
	total := end + 4 + length
	if length < 0 || len(b) < total {
		return 0
	}
	return total
}
