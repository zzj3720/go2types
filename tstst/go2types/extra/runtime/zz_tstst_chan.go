package runtime

// Channels on the tstst runtime, used by the code go2types generates for
// make(chan), sends, receives, select, close, len and cap. Goroutines run
// one at a time and switch only in tststPark, so the state needs no locks;
// every change others may wait for ends with tststWake. Values are boxed in
// interfaces. A blocked send has already put its value in buf, and waits
// until it is within the capacity of what has been received.

type tststChan struct {
	buf         []any
	cap         int
	closed      bool
	sent        int
	received    int
	recvWaiting int // receivers blocked on the channel (in a receive or a select)
	sendWaiting int // selects blocked with a send on the channel
}

func tststMakechan(size int) *tststChan {
	if size < 0 {
		panic(plainError("makechan: size out of range"))
	}
	return &tststChan{cap: size}
}

func tststChanSend(c *tststChan, v any) {
	if c == nil {
		for {
			tststPark()
		}
	}
	if c.closed {
		panic(plainError("send on closed channel"))
	}
	c.buf = append(c.buf, v)
	c.sent++
	n := c.sent
	tststWake()
	for n > c.received+c.cap {
		tststPark()
	}
}

func tststChanRecv(c *tststChan) (any, bool) {
	if c == nil {
		for {
			tststPark()
		}
	}
	for len(c.buf) == 0 {
		if c.closed {
			return nil, false
		}
		c.recvWaiting++
		if c.sendWaiting > 0 {
			// a select waiting to send can now hand its value over
			tststWake()
		}
		tststPark()
		c.recvWaiting--
	}
	return c.take(), true
}

func (c *tststChan) take() any {
	v := c.buf[0]
	c.buf[0] = nil
	c.buf = c.buf[1:]
	c.received++
	tststWake()
	return v
}

// for select: a receive that can proceed now (ready), with its value
func tststChanTryRecv(c *tststChan) (v any, ok bool, ready bool) {
	if c == nil {
		return nil, false, false
	}
	if len(c.buf) > 0 {
		return c.take(), true, true
	}
	if c.closed {
		return nil, false, true
	}
	return nil, false, false
}

// for select: a send that can proceed now (room in the buffer, or a
// receiver waiting for it)
func tststChanTrySend(c *tststChan, v any) bool {
	if c == nil {
		return false
	}
	if c.closed {
		panic(plainError("send on closed channel"))
	}
	if len(c.buf) < c.cap || c.recvWaiting > len(c.buf) {
		c.buf = append(c.buf, v)
		c.sent++
		tststWake()
		return true
	}
	return false
}

// a blocked select counts as a receiver on its receive channels (which lets
// selects waiting to send there go on)
func tststChanWaiting(c *tststChan, delta int) {
	if c != nil {
		c.recvWaiting += delta
		if delta > 0 && c.sendWaiting > 0 {
			tststWake()
		}
	}
}

// and as a waiting sender on its send channels
func tststChanSendWaiting(c *tststChan, delta int) {
	if c != nil {
		c.sendWaiting += delta
	}
}

func tststSelectPark() { tststPark() }

func tststChanClose(c *tststChan) {
	if c == nil {
		panic(plainError("close of nil channel"))
	}
	if c.closed {
		panic(plainError("close of closed channel"))
	}
	c.closed = true
	tststWake()
}

func tststChanLen(c *tststChan) int {
	if c == nil {
		return 0
	}
	if n := len(c.buf); n < c.cap {
		return n
	}
	return c.cap
}

func tststChanCap(c *tststChan) int {
	if c == nil {
		return 0
	}
	return c.cap
}
