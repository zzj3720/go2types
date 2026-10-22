package syscall

import "unsafe"

// An in-memory Linux kernel for programs on the tstst runtime (they are
// compiled for linux/amd64). Every system call of package syscall, x/sys/unix
// and internal/syscall/unix ends here (go2types forwards
// internal/runtime/syscall/linux.Syscall6 and x/sys/unix's Syscall
// functions), with the raw arguments: pointers are cell addresses, so the
// kernel reads and writes the caller's memory through them.
//
// It provides a file system (directories, regular files, symlinks, hard
// links), file descriptors, pipes, poll and inotify. The process starts with
// an empty file system holding /tmp and the working directory /tsc; forked
// test processes get a copy. Blocking calls park the goroutine until another
// one changes the kernel state (tststWake) or, for timeouts, until the virtual
// clock of package time reaches them.
//
// Records the program reads through a typed pointer into a byte buffer
// (inotify events; directory entries, which x/sys users read as
// *unix.Dirent while package os reads their bytes) are laid out for both
// readings: a struct field takes one cell on the tstst runtime, a byte one
// cell too, so the fields sit in the first cells and the bytes os reads at
// their Linux offsets.

func tststPark()
func tststWake()
func tststOutput(s string)

// set by package time: the virtual clock (Unix ns) and a sleep on it
var (
	TststNanotime func() int64
	TststSleep    func(ns int64)
)

const (
	kAtFdcwd           = -100
	kAtSymlinkNofollow = 0x100
	kAtRemovedir       = 0x200
	kAtSymlinkFollow   = 0x400
	kAtEmptyPath       = 0x1000
	kUtimeNow          = (1 << 30) - 1
	kUtimeOmit         = (1 << 30) - 2
	kRenameNoreplace   = 1
	kRenameExchange    = 2
	kOPath             = 0x200000
	kUid               = 1000

	kInAccess       = 0x1
	kInModify       = 0x2
	kInAttrib       = 0x4
	kInCloseWrite   = 0x8
	kInCloseNowrite = 0x10
	kInOpen         = 0x20
	kInMovedFrom    = 0x40
	kInMovedTo      = 0x80
	kInCreate       = 0x100
	kInDelete       = 0x200
	kInDeleteSelf   = 0x400
	kInMoveSelf     = 0x800
	kInIgnored      = 0x8000
	kInOnlydir      = 0x1000000
	kInDontFollow   = 0x2000000
	kInExclUnlink   = 0x4000000
	kInMaskCreate   = 0x10000000
	kInMaskAdd      = 0x20000000
	kInIsdir        = 0x40000000
	kInOneshot      = 0x80000000
	kInAllEvents    = 0xfff

	kPollIn   = 0x1
	kPollOut  = 0x4
	kPollErr  = 0x8
	kPollHup  = 0x10
	kPollNval = 0x20
)

type kNode struct {
	ino     uint64
	mode    uint32 // type and permission bits
	uid     uint32 // the owner: the process (1000) or root
	nlink   uint64
	data    []byte            // regular files
	sdata   string            // or, until written, their content as given
	str     bool              // whether sdata holds the content
	kids    map[string]*kNode // directories
	parent  *kNode            // directories: the containing one; others: where last linked
	name    string            // the name in parent
	link    string            // symlinks
	atime   int64
	mtime   int64
	ctime   int64
	watches []*kWatch
	marks   []*kFanMark // fanotify
}

func (n *kNode) isDir() bool { return n.mode&S_IFMT == S_IFDIR }

// whether the process (uid 1000, not root) may access n as want (4 read,
// 2 write, 1 search/execute)
func (n *kNode) may(want uint32) bool {
	bits := n.mode & 7
	if n.uid == kUid {
		bits = n.mode >> 6 & 7
	}
	return bits&want == want
}

func (n *kNode) size() int {
	if n.str {
		return len(n.sdata)
	}
	return len(n.data)
}

// makes the content writable
func (n *kNode) own() {
	if n.str {
		n.data = []byte(n.sdata)
		n.sdata, n.str = "", false
	}
}
func (n *kNode) isLink() bool { return n.mode&S_IFMT == S_IFLNK }

type kPipe struct {
	buf     []byte
	readers int
	writers int
}

type kEvent struct {
	wd     int
	mask   uint32
	cookie uint32
	name   string
}

type kInotify struct {
	events  []kEvent
	watches map[int]*kWatch
	nextWd  int
}

type kWatch struct {
	in   *kInotify
	wd   int
	node *kNode
	mask uint32
}

// an open file description
type kFile struct {
	node     *kNode
	path     string // directories: their path when opened
	off      int64
	flags    int
	pipe     *kPipe
	pipeW    bool // the write end
	inotify  *kInotify
	fanotify *kFanotify
	refs     int
	dirNames []string // directory listing from the first getdents
	listed   bool
	stdio    bool // the process's stdin/stdout/stderr
}

type kKernel struct {
	root    *kNode
	cwd     *kNode
	fds     map[int]*kFile
	nextIno uint64
	cookie  uint32
	umask   uint32
	rand    uint64
}

var kk *kKernel

func kNow() int64 {
	if TststNanotime != nil {
		return TststNanotime()
	}
	return 946684800 * 1e9
}

func kGet() *kKernel {
	if kk == nil {
		k := &kKernel{fds: map[int]*kFile{}, nextIno: 2, umask: 0o22, rand: 0x9e3779b97f4a7c15}
		k.root = k.newNode(S_IFDIR | 0o755)
		k.root.uid = 0
		k.root.parent = k.root
		k.root.nlink = 2
		tmp := k.newNode(S_IFDIR | 0o1777)
		tmp.uid = 0
		k.link(k.root, "tmp", tmp)
		tsc := k.newNode(S_IFDIR | 0o755)
		k.link(k.root, "tsc", tsc)
		home := k.newNode(S_IFDIR | 0o755)
		home.uid = 0
		k.link(k.root, "home", home)
		k.link(home, "tstst", k.newNode(S_IFDIR|0o755))
		k.cwd = tsc
		for fd := 0; fd < 3; fd++ {
			k.fds[fd] = &kFile{stdio: true, refs: 1, flags: O_RDWR}
		}
		kk = k
	}
	return kk
}

func (k *kKernel) newNode(mode uint32) *kNode {
	now := kNow()
	n := &kNode{ino: k.nextIno, mode: mode, uid: kUid, nlink: 1, atime: now, mtime: now, ctime: now}
	k.nextIno++
	if n.isDir() {
		n.kids = map[string]*kNode{}
	}
	return n
}

// adds n to directory d as name
func (k *kKernel) link(d *kNode, name string, n *kNode) {
	d.kids[name] = n
	if n.isDir() {
		n.nlink = 2
		n.parent = d
		d.nlink++
	} else if n.parent == nil {
		n.parent = d
	}
	n.name = name
	now := kNow()
	d.mtime, d.ctime = now, now
}

func (k *kKernel) unlink(d *kNode, name string) {
	n := d.kids[name]
	delete(d.kids, name)
	if n.isDir() {
		d.nlink--
		n.nlink = 0
	} else {
		n.nlink--
	}
	now := kNow()
	d.mtime, d.ctime, n.ctime = now, now, now
}

// path of directory d
func (k *kKernel) pathOf(d *kNode) string {
	if d == k.root {
		return "/"
	}
	p := ""
	for d != k.root {
		if d.parent == nil || d.parent.kids[d.name] != d {
			return "(unreachable)" + p
		}
		p = "/" + d.name + p
		d = d.parent
	}
	return p
}

// ---------------------------------------------------------------------------
// memory of the calling program

func kNil(p uintptr) bool { return unsafe.Pointer(p) == nil || p == 0 }

func kCString(p uintptr) string {
	if kNil(p) {
		return ""
	}
	var b []byte
	for {
		c := *(*byte)(unsafe.Pointer(p))
		if c == 0 {
			break
		}
		b = append(b, c)
		p++
	}
	return string(b)
}

func kBytes(p uintptr, n int) []byte {
	if n <= 0 || kNil(p) {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(p)), n)
}

// ---------------------------------------------------------------------------
// path lookup

// resolves path relative to dirfd: the directory holding the last component,
// its name and the node (nil if it does not exist)
func (k *kKernel) lookup(dirfd int, path string, follow bool) (*kNode, string, *kNode, Errno) {
	if path == "" {
		return nil, "", nil, ENOENT
	}
	base := k.cwd
	if path[0] != '/' && dirfd != kAtFdcwd {
		f := k.fds[dirfd]
		if f == nil {
			return nil, "", nil, EBADF
		}
		if f.node == nil || !f.node.isDir() {
			return nil, "", nil, ENOTDIR
		}
		base = f.node
	}
	return k.walk(base, path, follow, 0)
}

func (k *kKernel) walk(cur *kNode, path string, follow bool, depth int) (*kNode, string, *kNode, Errno) {
	if depth > 40 {
		return nil, "", nil, ELOOP
	}
	if len(path) > 0 && path[0] == '/' {
		cur = k.root
	}
	var comps []string
	start := 0
	for i := 0; i <= len(path); i++ {
		if i == len(path) || path[i] == '/' {
			if i > start {
				comps = append(comps, path[start:i])
			}
			start = i + 1
		}
	}
	trailingSlash := len(path) > 1 && path[len(path)-1] == '/'
	if len(comps) == 0 {
		return cur.parent, ".", cur, 0
	}
	for i, c := range comps {
		last := i == len(comps)-1
		if !cur.isDir() {
			return nil, "", nil, ENOTDIR
		}
		if len(c) > 255 {
			return nil, "", nil, ENAMETOOLONG
		}
		if !cur.may(1) {
			return nil, "", nil, EACCES
		}
		if c == "." || c == ".." {
			if c == ".." {
				cur = cur.parent
			}
			if last {
				return cur.parent, c, cur, 0
			}
			continue
		}
		child := cur.kids[c]
		if child != nil && child.isLink() && (!last || follow || trailingSlash) {
			_, _, t, e := k.walk(cur, child.link, true, depth+1)
			if e != 0 {
				return nil, "", nil, e
			}
			if t == nil {
				if last {
					// a dangling symlink: creating through it makes its target
					p, name, _, e := k.walk(cur, child.link, false, depth+1)
					return p, name, nil, e
				}
				return nil, "", nil, ENOENT
			}
			child = t
		}
		if last {
			if trailingSlash && child != nil && !child.isDir() {
				return nil, "", nil, ENOTDIR
			}
			return cur, c, child, 0
		}
		if child == nil {
			return nil, "", nil, ENOENT
		}
		cur = child
	}
	return nil, "", nil, ENOENT
}

// ---------------------------------------------------------------------------
// inotify

func (k *kKernel) notify(n *kNode, mask uint32, cookie uint32, name string) {
	if n == nil {
		return
	}
	for _, w := range n.watches {
		if w.mask&mask&kInAllEvents == 0 && mask&kInIgnored == 0 {
			continue
		}
		ev := kEvent{wd: w.wd, mask: mask, cookie: cookie, name: name}
		in := w.in
		if l := len(in.events); l > 0 {
			if p := in.events[l-1]; p == ev {
				continue
			}
		}
		in.events = append(in.events, ev)
		if w.mask&kInOneshot != 0 {
			k.rmWatch(w, true)
		}
	}
	tststWake()
}

// an event on child (named name in dir): to watchers of the child and of the dir
func (k *kKernel) notifyBoth(dir *kNode, name string, child *kNode, mask uint32) {
	isdir := uint32(0)
	if child != nil && child.isDir() {
		isdir = kInIsdir
	}
	k.notify(child, mask|isdir, 0, "")
	k.notify(dir, mask|isdir, 0, name)
	if mask&kFanDirent != 0 {
		k.fanDirent(dir, name, child, mask)
	} else if child != nil {
		k.fanInode(dir, name, child, mask)
	}
}

func (k *kKernel) rmWatch(w *kWatch, ignored bool) {
	n := w.node
	for i, x := range n.watches {
		if x == w {
			n.watches = append(n.watches[:i:i], n.watches[i+1:]...)
			break
		}
	}
	delete(w.in.watches, w.wd)
	if ignored {
		w.in.events = append(w.in.events, kEvent{wd: w.wd, mask: kInIgnored})
		tststWake()
	}
}

// a node lost its last link
func (k *kKernel) gone(n *kNode) {
	k.notify(n, kInDeleteSelf, 0, "")
	k.fanSelf(n, kInDeleteSelf)
	for _, m := range n.marks {
		m.g.marked = kRemoveNode(m.g.marked, n)
	}
	n.marks = nil
	for len(n.watches) > 0 {
		k.rmWatch(n.watches[0], true)
	}
}

// ---------------------------------------------------------------------------
// file descriptors

func (k *kKernel) allocFd(f *kFile, min int) int {
	fd := min
	for k.fds[fd] != nil {
		fd++
	}
	k.fds[fd] = f
	f.refs++
	return fd
}

func (k *kKernel) closeFd(fd int) Errno {
	f := k.fds[fd]
	if f == nil {
		return EBADF
	}
	delete(k.fds, fd)
	f.refs--
	if f.refs > 0 {
		return 0
	}
	switch {
	case f.pipe != nil:
		if f.pipeW {
			f.pipe.writers--
		} else {
			f.pipe.readers--
		}
		tststWake()
	case f.inotify != nil:
		for _, w := range f.inotify.watches {
			k.rmWatch(w, false)
		}
	case f.fanotify != nil:
		for _, n := range f.fanotify.marked {
			for i, m := range n.marks {
				if m.g == f.fanotify {
					n.marks = append(n.marks[:i:i], n.marks[i+1:]...)
					break
				}
			}
		}
		f.fanotify.marked = nil
	case f.node != nil:
		if f.flags&O_ACCMODE != O_RDONLY {
			k.notifyParent(f.node, kInCloseWrite)
		} else {
			k.notifyParent(f.node, kInCloseNowrite)
		}
	}
	return 0
}

func (k *kKernel) notifyParent(n *kNode, mask uint32) {
	if n.parent != nil && n.parent.kids[n.name] == n && n.parent != n {
		k.notifyBoth(n.parent, n.name, n, mask)
	} else {
		k.notifyBoth(nil, "", n, mask)
	}
}

func (k *kKernel) file(fd int) (*kFile, Errno) {
	f := k.fds[fd]
	if f == nil {
		return nil, EBADF
	}
	return f, 0
}

// waits until ready, or the timeout (ns; < 0 none) passes: whether ready
func kBlock(ready func() bool, timeout int64) bool {
	if ready() {
		return true
	}
	if timeout == 0 {
		return false
	}
	expired := false
	if timeout > 0 && TststSleep != nil {
		go func() {
			TststSleep(timeout)
			expired = true
			tststWake()
		}()
	}
	for !ready() {
		if expired {
			return false
		}
		tststPark()
	}
	return true
}

// ---------------------------------------------------------------------------
// system calls

func kErr(e Errno) (uintptr, uintptr, uintptr) { return ^uintptr(0), 0, uintptr(e) }
func kOk(r int) (uintptr, uintptr, uintptr)    { return uintptr(r), 0, 0 }
func kRes(r int, e Errno) (uintptr, uintptr, uintptr) {
	if e != 0 {
		return kErr(e)
	}
	return kOk(r)
}

func tststSyscall6(num, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2, errno uintptr) {
	k := kGet()
	switch num {
	case SYS_READ:
		return kRes(k.read(int(int32(a1)), kBytes(a2, int(a3)), -1))
	case SYS_PREAD64:
		return kRes(k.read(int(int32(a1)), kBytes(a2, int(a3)), int64(a4)))
	case SYS_WRITE:
		return kRes(k.write(int(int32(a1)), kBytes(a2, int(a3)), -1))
	case SYS_PWRITE64:
		return kRes(k.write(int(int32(a1)), kBytes(a2, int(a3)), int64(a4)))
	case SYS_CLOSE:
		return kRes(0, k.closeFd(int(int32(a1))))
	case SYS_OPENAT:
		return kRes(k.open(int(int32(a1)), kCString(a2), int(int32(a3)), uint32(a4)))
	case SYS_FSTAT:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		k.stat(f, f.node, a2)
		return kOk(0)
	case SYS_NEWFSTATAT:
		flags := int(a4)
		path := kCString(a2)
		if path == "" && flags&kAtEmptyPath != 0 {
			f, e := k.file(int(int32(a1)))
			if e != 0 {
				return kErr(e)
			}
			k.stat(f, f.node, a3)
			return kOk(0)
		}
		_, _, n, e := k.lookup(int(int32(a1)), path, flags&kAtSymlinkNofollow == 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return kErr(e)
		}
		k.stat(nil, n, a3)
		return kOk(0)
	case SYS_LSEEK:
		return k.lseek(int(int32(a1)), int64(a2), int(a3))
	case SYS_GETDENTS64:
		return kRes(k.getdents(int(int32(a1)), kBytes(a2, int(a3))))
	case SYS_MKDIRAT:
		return kRes(0, k.mkdir(int(int32(a1)), kCString(a2), uint32(a3)))
	case SYS_MKNODAT:
		return kErr(EPERM)
	case SYS_UNLINKAT:
		return kRes(0, k.unlinkat(int(int32(a1)), kCString(a2), int(a3)))
	case SYS_RENAMEAT:
		return kRes(0, k.rename(int(int32(a1)), kCString(a2), int(int32(a3)), kCString(a4), 0))
	case 316: // renameat2
		return kRes(0, k.rename(int(int32(a1)), kCString(a2), int(int32(a3)), kCString(a4), int(a5)))
	case SYS_SYMLINKAT:
		return kRes(0, k.symlink(kCString(a1), int(int32(a2)), kCString(a3)))
	case SYS_READLINKAT:
		_, _, n, e := k.lookup(int(int32(a1)), kCString(a2), false)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return kErr(e)
		}
		if !n.isLink() {
			return kErr(EINVAL)
		}
		buf := kBytes(a3, int(a4))
		return kOk(copy(buf, n.link))
	case SYS_LINKAT:
		return kRes(0, k.hardlink(int(int32(a1)), kCString(a2), int(int32(a3)), kCString(a4), int(a5)))
	case SYS_FCHMODAT, 452: // fchmodat2
		_, _, n, e := k.lookup(int(int32(a1)), kCString(a2), int(a4)&kAtSymlinkNofollow == 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return kErr(e)
		}
		k.chmod(n, uint32(a3))
		return kOk(0)
	case SYS_FCHMOD:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		if f.node != nil {
			k.chmod(f.node, uint32(a2))
		}
		return kOk(0)
	case SYS_FCHOWNAT, SYS_FCHOWN:
		return kOk(0)
	case SYS_UTIMENSAT:
		return kRes(0, k.utimens(int(int32(a1)), a2, a3, int(a4)))
	case SYS_FACCESSAT, 439: // faccessat2
		_, _, n, e := k.lookup(int(int32(a1)), kCString(a2), int(a4)&kAtSymlinkNofollow == 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e == 0 && !n.may(uint32(a3)&7) {
			e = EACCES
		}
		return kRes(0, e)
	case SYS_TRUNCATE:
		_, _, n, e := k.lookup(kAtFdcwd, kCString(a1), true)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return kErr(e)
		}
		return kRes(0, k.truncate(n, int64(a2)))
	case SYS_FTRUNCATE:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		if f.node == nil || f.flags&O_ACCMODE == O_RDONLY {
			return kErr(EINVAL)
		}
		return kRes(0, k.truncate(f.node, int64(a2)))
	case SYS_FSYNC, SYS_FDATASYNC, SYS_FADVISE64, SYS_FLOCK, SYS_SYNC_FILE_RANGE:
		if _, e := k.file(int(int32(a1))); e != 0 {
			return kErr(e)
		}
		return kOk(0)
	case SYS_GETCWD:
		p := k.pathOf(k.cwd)
		buf := kBytes(a1, int(a2))
		if len(p)+1 > len(buf) {
			return kErr(ERANGE)
		}
		copy(buf, p)
		buf[len(p)] = 0
		return kOk(len(p) + 1)
	case SYS_CHDIR:
		_, _, n, e := k.lookup(kAtFdcwd, kCString(a1), true)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e == 0 && !n.isDir() {
			e = ENOTDIR
		}
		if e != 0 {
			return kErr(e)
		}
		k.cwd = n
		return kOk(0)
	case SYS_FCHDIR:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		if f.node == nil || !f.node.isDir() {
			return kErr(ENOTDIR)
		}
		k.cwd = f.node
		return kOk(0)
	case SYS_FCNTL:
		return k.fcntl(int(int32(a1)), int(a2), int(a3))
	case SYS_DUP:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		return kOk(k.allocFd(f, 0))
	case SYS_DUP2, SYS_DUP3:
		old, nfd := int(int32(a1)), int(int32(a2))
		f, e := k.file(old)
		if e != 0 {
			return kErr(e)
		}
		if old == nfd {
			if num == SYS_DUP3 {
				return kErr(EINVAL)
			}
			return kOk(nfd)
		}
		if k.fds[nfd] != nil {
			k.closeFd(nfd)
		}
		k.fds[nfd] = f
		f.refs++
		return kOk(nfd)
	case SYS_PIPE2:
		p := &kPipe{readers: 1, writers: 1}
		nb := int(a2) & O_NONBLOCK
		r := k.allocFd(&kFile{pipe: p, flags: O_RDONLY | nb}, 0)
		w := k.allocFd(&kFile{pipe: p, pipeW: true, flags: O_WRONLY | nb}, 0)
		fds := (*[2]int32)(unsafe.Pointer(a1))
		fds[0], fds[1] = int32(r), int32(w)
		return kOk(0)
	case SYS_POLL:
		return kRes(k.poll(a1, int(a2), int64(int32(a3))*1e6))
	case SYS_PPOLL:
		timeout := int64(-1)
		if !kNil(a3) {
			ts := (*Timespec)(unsafe.Pointer(a3))
			timeout = ts.Sec*1e9 + ts.Nsec
		}
		return kRes(k.poll(a1, int(a2), timeout))
	case SYS_INOTIFY_INIT1:
		in := &kInotify{watches: map[int]*kWatch{}, nextWd: 1}
		return kOk(k.allocFd(&kFile{inotify: in, flags: O_RDONLY | int(a1)&O_NONBLOCK}, 0))
	case SYS_INOTIFY_ADD_WATCH:
		return kRes(k.addWatch(int(int32(a1)), kCString(a2), uint32(a3)))
	case SYS_INOTIFY_RM_WATCH:
		f, e := k.file(int(int32(a1)))
		if e != 0 {
			return kErr(e)
		}
		if f.inotify == nil {
			return kErr(EINVAL)
		}
		w := f.inotify.watches[int(int32(a2))]
		if w == nil {
			return kErr(EINVAL)
		}
		k.rmWatch(w, true)
		return kOk(0)
	case SYS_FANOTIFY_INIT:
		nb := 0
		if a1&kFanNonblock != 0 {
			nb = O_NONBLOCK
		}
		return kOk(k.allocFd(&kFile{fanotify: &kFanotify{}, flags: O_RDONLY | nb}, 0))
	case SYS_FANOTIFY_MARK:
		return kRes(0, k.fanMark(int(int32(a1)), uint(a2), uint64(a3), int(int32(a4)), a5))
	case 303: // name_to_handle_at
		_, _, n, e := k.lookup(int(int32(a1)), kCString(a2), int(a5)&kAtSymlinkFollow != 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return kErr(e)
		}
		// struct file_handle as two cells (handle_bytes, handle_type); x/sys
		// finds the handle 4 bytes (here: cells) after handle_type
		fh := (*[2]uint32)(unsafe.Pointer(a3))
		if fh[0] < 8 {
			fh[0] = 8
			return kErr(EOVERFLOW)
		}
		fh[0], fh[1] = 8, 1
		copy(kBytes(a3+5, 8), kHandle(n))
		if !kNil(a4) {
			*(*int32)(unsafe.Pointer(a4)) = 1
		}
		return kOk(0)
	case SYS_STATFS, SYS_FSTATFS:
		if num == SYS_STATFS {
			_, _, n, e := k.lookup(kAtFdcwd, kCString(a1), true)
			if e == 0 && n == nil {
				e = ENOENT
			}
			if e != 0 {
				return kErr(e)
			}
		} else if _, e := k.file(int(int32(a1))); e != 0 {
			return kErr(e)
		}
		st := (*Statfs_t)(unsafe.Pointer(a2))
		*st = Statfs_t{Type: 0x01021994, Bsize: 4096, Blocks: 1 << 20, Bfree: 1 << 19, Bavail: 1 << 19, Files: 1 << 20, Ffree: 1 << 19, Namelen: 255, Frsize: 4096}
		return kOk(0)
	case 318: // getrandom
		buf := kBytes(a1, int(a2))
		for i := range buf {
			k.rand ^= k.rand << 13
			k.rand ^= k.rand >> 7
			k.rand ^= k.rand << 17
			buf[i] = byte(k.rand)
		}
		return kOk(len(buf))
	case SYS_GETPID, SYS_GETTID:
		return kOk(1000)
	case SYS_GETPPID:
		return kOk(1)
	case SYS_GETUID, SYS_GETEUID, SYS_GETGID, SYS_GETEGID:
		return kOk(1000)
	case SYS_UMASK:
		old := k.umask
		k.umask = uint32(a1) & 0o777
		return kOk(int(old))
	case SYS_UNAME:
		u := (*Utsname)(unsafe.Pointer(a1))
		kPutStr(u.Sysname[:], "Linux")
		kPutStr(u.Nodename[:], "tstst")
		kPutStr(u.Release[:], "6.8.0")
		kPutStr(u.Version[:], "#1 SMP")
		kPutStr(u.Machine[:], "x86_64")
		kPutStr(u.Domainname[:], "(none)")
		return kOk(0)
	case SYS_SCHED_YIELD, SYS_KILL, SYS_TGKILL:
		return kOk(0)
	case SYS_NANOSLEEP:
		ts := (*Timespec)(unsafe.Pointer(a1))
		if TststSleep != nil {
			TststSleep(ts.Sec*1e9 + ts.Nsec)
		}
		return kOk(0)
	case SYS_IOCTL:
		return kErr(ENOTTY)
	}
	return kErr(ENOSYS)
}

// the process's environment
func tstst_runtime_envs() []string {
	return []string{"HOME=/home/tstst", "PATH=/usr/local/bin:/usr/bin:/bin", "USER=tstst"}
}

func kPutStr(dst []int8, s string) {
	for i := 0; i < len(s) && i < len(dst)-1; i++ {
		dst[i] = int8(s[i])
	}
}

// no process can start another one: fork fails
func tstst_rawVforkSyscall(trap, a1, a2, a3 uintptr) (r1 uintptr, err Errno) { return 0, ENOSYS }

func tstst_rawSyscallNoError(trap, a1, a2, a3 uintptr) (r1, r2 uintptr) {
	r1, r2, _ = tststSyscall6(trap, a1, a2, a3, 0, 0, 0)
	return
}

func (k *kKernel) stat(f *kFile, n *kNode, p uintptr) {
	st := (*Stat_t)(unsafe.Pointer(p))
	if n == nil {
		// pipes, inotify, stdio
		mode := uint32(S_IFIFO | 0o600)
		if f != nil && f.stdio {
			mode = S_IFCHR | 0o620
		} else if f != nil && f.inotify != nil {
			mode = S_IFREG | 0o600
		}
		*st = Stat_t{Dev: 12, Ino: 1, Nlink: 1, Mode: mode, Uid: 1000, Gid: 1000, Blksize: 4096}
		return
	}
	size := int64(n.size())
	if n.isDir() {
		size = 4096
	} else if n.isLink() {
		size = int64(len(n.link))
	}
	*st = Stat_t{
		Dev: 0x801, Ino: n.ino, Nlink: n.nlink, Mode: n.mode, Uid: n.uid, Gid: n.uid,
		Size: size, Blksize: 4096, Blocks: (size + 511) / 512,
		Atim: Timespec{Sec: n.atime / 1e9, Nsec: n.atime % 1e9},
		Mtim: Timespec{Sec: n.mtime / 1e9, Nsec: n.mtime % 1e9},
		Ctim: Timespec{Sec: n.ctime / 1e9, Nsec: n.ctime % 1e9},
	}
}

func (k *kKernel) open(dirfd int, path string, flags int, mode uint32) (int, Errno) {
	creat := flags&O_CREAT != 0
	excl := creat && flags&O_EXCL != 0
	follow := flags&O_NOFOLLOW == 0 && !excl
	dir, name, n, e := k.lookup(dirfd, path, follow)
	if e != 0 {
		return 0, e
	}
	acc := flags & O_ACCMODE
	if n == nil {
		if !creat {
			return 0, ENOENT
		}
		if dir == nil || name == "." || name == ".." {
			return 0, EISDIR
		}
		if flags&O_DIRECTORY != 0 {
			return 0, EINVAL
		}
		if !dir.may(3) {
			return 0, EACCES
		}
		n = k.newNode(S_IFREG | (mode & 0o7777 &^ k.umask))
		k.link(dir, name, n)
		k.notifyBoth(dir, name, nil, kInCreate)
	} else {
		if excl {
			return 0, EEXIST
		}
		if n.isLink() {
			if flags&kOPath != 0 {
				// fine: refers to the link itself
			} else {
				return 0, ELOOP
			}
		}
		if flags&O_DIRECTORY != 0 && !n.isDir() {
			return 0, ENOTDIR
		}
		if n.isDir() && (acc != O_RDONLY || flags&O_TRUNC != 0) {
			return 0, EISDIR
		}
		if flags&kOPath == 0 && (acc != O_WRONLY && !n.may(4) || (acc != O_RDONLY || flags&O_TRUNC != 0) && !n.may(2)) {
			return 0, EACCES
		}
		if flags&O_TRUNC != 0 && acc != O_RDONLY && n.mode&S_IFMT == S_IFREG {
			if n.size() > 0 {
				n.data, n.sdata, n.str = nil, "", false
				now := kNow()
				n.mtime, n.ctime = now, now
				k.notifyParent(n, kInModify)
			}
		}
	}
	f := &kFile{node: n, flags: flags &^ (O_CREAT | O_EXCL | O_TRUNC | O_NOCTTY | O_CLOEXEC)}
	if n.isDir() {
		f.path = k.pathOf(n)
	}
	k.notifyParent(n, kInOpen)
	return k.allocFd(f, 0), 0
}

func (k *kKernel) read(fd int, buf []byte, at int64) (int, Errno) {
	f, e := k.file(fd)
	if e != 0 {
		return 0, e
	}
	if f.flags&O_ACCMODE == O_WRONLY {
		return 0, EBADF
	}
	switch {
	case f.stdio:
		return 0, 0
	case f.pipe != nil:
		if at >= 0 {
			return 0, ESPIPE
		}
		if f.pipeW {
			return 0, EBADF
		}
		p := f.pipe
		if len(buf) == 0 {
			return 0, 0
		}
		nb := f.flags&O_NONBLOCK != 0
		timeout := int64(-1)
		if nb {
			timeout = 0
		}
		if !kBlock(func() bool { return len(p.buf) > 0 || p.writers == 0 }, timeout) {
			return 0, EAGAIN
		}
		n := copy(buf, p.buf)
		p.buf = p.buf[n:]
		tststWake()
		return n, 0
	case f.fanotify != nil:
		return k.fanRead(f, buf)
	case f.inotify != nil:
		in := f.inotify
		nb := f.flags&O_NONBLOCK != 0
		timeout := int64(-1)
		if nb {
			timeout = 0
		}
		if !kBlock(func() bool { return len(in.events) > 0 }, timeout) {
			return 0, EAGAIN
		}
		n := 0
		for len(in.events) > 0 {
			ev := in.events[0]
			l := 0
			if ev.name != "" {
				l = (len(ev.name) + 16) / 16 * 16
			}
			if n+16+l > len(buf) {
				if n == 0 {
					return 0, EINVAL
				}
				break
			}
			// struct inotify_event as four cells (see the top)
			rec := buf[n : n+16+l]
			for i := range rec {
				rec[i] = 0
			}
			*(*InotifyEvent)(unsafe.Pointer(&rec[0])) = InotifyEvent{Wd: int32(ev.wd), Mask: ev.mask, Cookie: ev.cookie, Len: uint32(l)}
			copy(rec[16:], ev.name)
			n += 16 + l
			in.events = in.events[1:]
		}
		return n, 0
	}
	n := f.node
	if n.isDir() {
		return 0, EISDIR
	}
	off := f.off
	if at >= 0 {
		off = at
	}
	if off >= int64(n.size()) {
		return 0, 0
	}
	var c int
	if n.str {
		c = copy(buf, n.sdata[off:])
	} else {
		c = copy(buf, n.data[off:])
	}
	if at < 0 {
		f.off += int64(c)
	}
	n.atime = kNow()
	k.notifyParent(n, kInAccess)
	return c, 0
}

func (k *kKernel) write(fd int, buf []byte, at int64) (int, Errno) {
	f, e := k.file(fd)
	if e != 0 {
		return 0, e
	}
	if f.flags&O_ACCMODE == O_RDONLY && !f.stdio {
		return 0, EBADF
	}
	switch {
	case f.stdio:
		if len(buf) > 0 {
			tststOutput(string(buf))
		}
		return len(buf), 0
	case f.pipe != nil:
		if at >= 0 {
			return 0, ESPIPE
		}
		if !f.pipeW {
			return 0, EBADF
		}
		if f.pipe.readers == 0 {
			return 0, EPIPE
		}
		f.pipe.buf = append(f.pipe.buf, buf...)
		tststWake()
		return len(buf), 0
	case f.inotify != nil:
		return 0, EINVAL
	}
	n := f.node
	if n.isDir() {
		return 0, EISDIR
	}
	n.own()
	off := f.off
	if f.flags&O_APPEND != 0 {
		off = int64(len(n.data))
	}
	if at >= 0 {
		off = at
	}
	end := off + int64(len(buf))
	if end > int64(len(n.data)) {
		if end <= int64(cap(n.data)) {
			n.data = n.data[:end]
		} else {
			d := make([]byte, end, end+end/2)
			copy(d, n.data)
			n.data = d
		}
	}
	copy(n.data[off:], buf)
	if at < 0 {
		f.off = end
	}
	now := kNow()
	n.mtime, n.ctime = now, now
	k.notifyParent(n, kInModify)
	return len(buf), 0
}

func (k *kKernel) lseek(fd int, off int64, whence int) (uintptr, uintptr, uintptr) {
	f, e := k.file(fd)
	if e != 0 {
		return kErr(e)
	}
	if f.node == nil {
		return kErr(ESPIPE)
	}
	var pos int64
	switch whence {
	case 0:
		pos = off
	case 1:
		pos = f.off + off
	case 2:
		pos = int64(f.node.size()) + off
	default:
		return kErr(EINVAL)
	}
	if pos < 0 {
		return kErr(EINVAL)
	}
	f.off = pos
	if f.node.isDir() && pos == 0 {
		f.listed = false
	}
	return uintptr(pos), 0, 0
}

func (k *kKernel) getdents(fd int, buf []byte) (int, Errno) {
	f, e := k.file(fd)
	if e != 0 {
		return 0, e
	}
	if f.node == nil || !f.node.isDir() {
		return 0, ENOTDIR
	}
	d := f.node
	if !f.listed {
		f.listed = true
		f.off = 0
		names := []string{".", ".."}
		var rest []string
		for name := range d.kids {
			rest = append(rest, name)
		}
		// sorted, for stable results
		for i := 1; i < len(rest); i++ {
			for j := i; j > 0 && rest[j] < rest[j-1]; j-- {
				rest[j], rest[j-1] = rest[j-1], rest[j]
			}
		}
		f.dirNames = append(names, rest...)
	}
	n := 0
	for int(f.off) < len(f.dirNames) {
		name := f.dirNames[f.off]
		var child *kNode
		switch name {
		case ".":
			child = d
		case "..":
			child = d.parent
		default:
			child = d.kids[name]
			if child == nil {
				// removed since the listing
				f.off++
				continue
			}
		}
		reclen := (19 + len(name) + 1 + 7) / 8 * 8
		if n+reclen > len(buf) {
			if n == 0 {
				return 0, EINVAL
			}
			break
		}
		typ := byte(DT_REG)
		switch child.mode & S_IFMT {
		case S_IFDIR:
			typ = DT_DIR
		case S_IFLNK:
			typ = DT_LNK
		case S_IFIFO:
			typ = DT_FIFO
		}
		rec := buf[n : n+reclen]
		for i := range rec {
			rec[i] = 0
		}
		// cells 0..3 as *Dirent fields (Ino, Off, Reclen, Type); bytes
		// 16..18 as Linux has them (Reclen, Type); the name from byte 19.
		// Package os reads Ino from bytes 0..7, only to skip zero ones.
		rec[0] = byte(child.ino)
		if rec[0] == 0 {
			rec[0] = 1
		}
		rec[2] = byte(reclen)
		rec[3] = typ
		rec[16] = byte(reclen)
		rec[17] = byte(reclen >> 8)
		rec[18] = typ
		copy(rec[19:], name)
		n += reclen
		f.off++
	}
	return n, 0
}

func (k *kKernel) mkdir(dirfd int, path string, mode uint32) Errno {
	dir, name, n, e := k.lookup(dirfd, path, false)
	if e != 0 {
		return e
	}
	if n != nil {
		return EEXIST
	}
	if dir == nil {
		return ENOENT
	}
	if !dir.may(3) {
		return EACCES
	}
	n = k.newNode(S_IFDIR | (mode & 0o7777 &^ k.umask))
	k.link(dir, name, n)
	k.notifyBoth(dir, name, n, kInCreate)
	return 0
}

func (k *kKernel) unlinkat(dirfd int, path string, flags int) Errno {
	dir, name, n, e := k.lookup(dirfd, path, false)
	if e != 0 {
		return e
	}
	if n == nil {
		return ENOENT
	}
	if !dir.may(3) {
		return EACCES
	}
	if flags&kAtRemovedir != 0 {
		if !n.isDir() {
			return ENOTDIR
		}
		if name == "." {
			return EINVAL
		}
		if len(n.kids) > 0 || name == ".." {
			return ENOTEMPTY
		}
		if n == k.root {
			return EBUSY
		}
	} else if n.isDir() {
		return EISDIR
	}
	k.unlink(dir, name)
	isdir := uint32(0)
	if n.isDir() {
		isdir = kInIsdir
	}
	if n.nlink == 0 {
		k.gone(n)
	} else {
		k.notify(n, kInAttrib, 0, "")
		k.fanInode(n.parent, n.name, n, kInAttrib)
	}
	k.notify(dir, kInDelete|isdir, 0, name)
	k.fanDirent(dir, name, n, kInDelete)
	return 0
}

func (k *kKernel) rename(oldfd int, oldpath string, newfd int, newpath string, flags int) Errno {
	od, oname, n, e := k.lookup(oldfd, oldpath, false)
	if e != 0 {
		return e
	}
	if n == nil {
		return ENOENT
	}
	if oname == "." || oname == ".." {
		return EBUSY
	}
	nd, nname, t, e := k.lookup(newfd, newpath, false)
	if e != 0 {
		return e
	}
	if nd == nil {
		return ENOENT
	}
	if nname == "." || nname == ".." {
		return EBUSY
	}
	if t == n {
		return 0
	}
	if !od.may(3) || !nd.may(3) {
		return EACCES
	}
	if flags&kRenameNoreplace != 0 && t != nil {
		return EEXIST
	}
	if n.isDir() {
		// not into itself
		for p := nd; ; p = p.parent {
			if p == n {
				return EINVAL
			}
			if p == k.root {
				break
			}
		}
	}
	if t != nil {
		if n.isDir() {
			if !t.isDir() {
				return ENOTDIR
			}
			if len(t.kids) > 0 {
				return ENOTEMPTY
			}
		} else if t.isDir() {
			return EISDIR
		}
		k.unlink(nd, nname)
	}
	delete(od.kids, oname)
	if n.isDir() {
		od.nlink--
		nd.nlink++
	}
	nd.kids[nname] = n
	n.parent = nd
	n.name = nname
	now := kNow()
	od.mtime, od.ctime, nd.mtime, nd.ctime, n.ctime = now, now, now, now, now
	k.cookie++
	isdir := uint32(0)
	if n.isDir() {
		isdir = kInIsdir
	}
	k.notify(od, kInMovedFrom|isdir, k.cookie, oname)
	k.notify(nd, kInMovedTo|isdir, k.cookie, nname)
	k.notify(n, kInMoveSelf, 0, "")
	k.fanRename(od, oname, nd, nname, n)
	k.fanDirent(od, oname, n, kInMovedFrom)
	k.fanDirent(nd, nname, n, kInMovedTo)
	k.fanSelf(n, kInMoveSelf)
	if t != nil {
		if t.isDir() || t.nlink == 0 {
			t.nlink = 0
			k.gone(t)
		}
	}
	return 0
}

func (k *kKernel) symlink(target string, dirfd int, path string) Errno {
	dir, name, n, e := k.lookup(dirfd, path, false)
	if e != 0 {
		return e
	}
	if n != nil {
		return EEXIST
	}
	if dir == nil {
		return ENOENT
	}
	if !dir.may(3) {
		return EACCES
	}
	n = k.newNode(S_IFLNK | 0o777)
	n.link = target
	k.link(dir, name, n)
	k.notifyBoth(dir, name, nil, kInCreate)
	return 0
}

func (k *kKernel) hardlink(oldfd int, oldpath string, newfd int, newpath string, flags int) Errno {
	_, _, n, e := k.lookup(oldfd, oldpath, flags&kAtSymlinkFollow != 0)
	if e != 0 {
		return e
	}
	if n == nil {
		return ENOENT
	}
	if n.isDir() {
		return EPERM
	}
	dir, name, t, e := k.lookup(newfd, newpath, false)
	if e != 0 {
		return e
	}
	if t != nil {
		return EEXIST
	}
	if dir == nil {
		return ENOENT
	}
	if !dir.may(3) {
		return EACCES
	}
	dir.kids[name] = n
	n.nlink++
	now := kNow()
	dir.mtime, dir.ctime, n.ctime = now, now, now
	k.notify(n, kInAttrib, 0, "")
	k.notify(dir, kInCreate, 0, name)
	k.fanInode(n.parent, n.name, n, kInAttrib)
	k.fanDirent(dir, name, n, kInCreate)
	return 0
}

func (k *kKernel) chmod(n *kNode, mode uint32) {
	n.mode = n.mode&S_IFMT | mode&0o7777
	n.ctime = kNow()
	k.notifyParent(n, kInAttrib)
}

func (k *kKernel) truncate(n *kNode, size int64) Errno {
	if n.isDir() {
		return EISDIR
	}
	if size < 0 {
		return EINVAL
	}
	n.own()
	if size <= int64(len(n.data)) {
		n.data = n.data[:size:size]
	} else {
		d := make([]byte, size)
		copy(d, n.data)
		n.data = d
	}
	now := kNow()
	n.mtime, n.ctime = now, now
	k.notifyParent(n, kInModify)
	return 0
}

func (k *kKernel) utimens(dirfd int, pathp, timesp uintptr, flags int) Errno {
	var n *kNode
	if kNil(pathp) {
		f, e := k.file(dirfd)
		if e != 0 {
			return e
		}
		n = f.node
		if n == nil {
			return 0
		}
	} else {
		var e Errno
		_, _, n, e = k.lookup(dirfd, kCString(pathp), flags&kAtSymlinkNofollow == 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return e
		}
	}
	now := kNow()
	at, mt := now, now
	if !kNil(timesp) {
		ts := (*[2]Timespec)(unsafe.Pointer(timesp))
		pick := func(t Timespec, cur int64) int64 {
			switch t.Nsec {
			case kUtimeNow:
				return now
			case kUtimeOmit:
				return cur
			}
			return t.Sec*1e9 + t.Nsec
		}
		at = pick(ts[0], n.atime)
		mt = pick(ts[1], n.mtime)
	}
	n.atime, n.mtime, n.ctime = at, mt, now
	k.notifyParent(n, kInAttrib)
	return 0
}

func (k *kKernel) fcntl(fd, cmd, arg int) (uintptr, uintptr, uintptr) {
	f, e := k.file(fd)
	if e != 0 {
		return kErr(e)
	}
	switch cmd {
	case F_DUPFD, F_DUPFD_CLOEXEC:
		return kOk(k.allocFd(f, arg))
	case F_GETFD, F_SETFD:
		return kOk(0)
	case F_GETFL:
		return kOk(f.flags)
	case F_SETFL:
		f.flags = f.flags&^(O_NONBLOCK|O_APPEND) | arg&(O_NONBLOCK|O_APPEND)
		return kOk(0)
	case F_GETLK, F_SETLK, F_SETLKW:
		return kOk(0)
	}
	return kErr(EINVAL)
}

type kPollFd struct {
	Fd      int32
	Events  int16
	Revents int16
}

func (k *kKernel) poll(p uintptr, nfds int, timeout int64) (int, Errno) {
	var fds []kPollFd
	if nfds > 0 {
		fds = unsafe.Slice((*kPollFd)(unsafe.Pointer(p)), nfds)
	}
	count := 0
	scan := func() bool {
		count = 0
		for i := range fds {
			pf := &fds[i]
			pf.Revents = 0
			if pf.Fd < 0 {
				continue
			}
			f := k.fds[int(pf.Fd)]
			var r int16
			switch {
			case f == nil:
				r = kPollNval
			case f.pipe != nil && !f.pipeW:
				if len(f.pipe.buf) > 0 {
					r |= kPollIn
				}
				if f.pipe.writers == 0 {
					r |= kPollHup
				}
			case f.pipe != nil:
				if f.pipe.readers == 0 {
					r |= kPollErr
				} else {
					r |= kPollOut
				}
			case f.inotify != nil:
				if len(f.inotify.events) > 0 {
					r |= kPollIn
				}
			case f.fanotify != nil:
				if len(f.fanotify.events) > 0 {
					r |= kPollIn
				}
			default:
				r |= kPollIn | kPollOut
			}
			r &= pf.Events | kPollHup | kPollErr | kPollNval
			pf.Revents = r
			if r != 0 {
				count++
			}
		}
		return count > 0
	}
	kBlock(scan, timeout)
	return count, 0
}

func (k *kKernel) addWatch(fd int, path string, mask uint32) (int, Errno) {
	f, e := k.file(fd)
	if e != 0 {
		return 0, e
	}
	if f.inotify == nil {
		return 0, EINVAL
	}
	if mask&kInAllEvents == 0 {
		return 0, EINVAL
	}
	_, _, n, e := k.lookup(kAtFdcwd, path, mask&kInDontFollow == 0)
	if e == 0 && n == nil {
		e = ENOENT
	}
	if e != 0 {
		return 0, e
	}
	if mask&kInOnlydir != 0 && !n.isDir() {
		return 0, ENOTDIR
	}
	in := f.inotify
	for _, w := range n.watches {
		if w.in == in {
			if mask&kInMaskCreate != 0 {
				return 0, EEXIST
			}
			if mask&kInMaskAdd != 0 {
				w.mask |= mask
			} else {
				w.mask = mask
			}
			return w.wd, 0
		}
	}
	w := &kWatch{in: in, wd: in.nextWd, node: n, mask: mask}
	in.nextWd++
	in.watches[w.wd] = w
	n.watches = append(n.watches, w)
	return w.wd, 0
}

// TststAddFile puts a file (and the directories above it) into the file
// system, as the program's input provides them.
func TststAddFile(path, content string) {
	k := kGet()
	d := k.root
	start := 1
	for i := 1; i <= len(path); i++ {
		if i < len(path) && path[i] != '/' {
			continue
		}
		name := path[start:i]
		start = i + 1
		if name == "" {
			continue
		}
		if i == len(path) {
			n := k.newNode(S_IFREG | 0o644)
			n.sdata, n.str = content, true
			k.link(d, name, n)
			return
		}
		next := d.kids[name]
		if next == nil {
			next = k.newNode(S_IFDIR | 0o755)
			k.link(d, name, next)
		}
		d = next
	}
}

// ---------------------------------------------------------------------------
// fanotify (FAN_REPORT_DFID_NAME: events name the directory and entry)

const (
	kFanNonblock     = 0x2
	kFanMarkAdd      = 0x1
	kFanMarkRemove   = 0x2
	kFanMarkDontFoll = 0x4
	kFanMarkOnlydir  = 0x8
	kFanMarkFlush    = 0x80
	kFanEventOnChild = 0x08000000
	kFanRename       = 0x10000000
	kFanOndir        = 0x40000000
	kFanDirent       = kInCreate | kInDelete | kInMovedFrom | kInMovedTo
	kFanAllowed      = 0x1fff | 0x4000 | 0x8000 | kFanEventOnChild | kFanRename | kFanOndir

	kFanInfoDfidName    = 2
	kFanInfoOldDfidName = 10
	kFanInfoNewDfidName = 12
)

type kFanotify struct {
	events []kFanEvent
	marked []*kNode
}

type kFanMark struct {
	g    *kFanotify
	mask uint64
}

type kFanEvent struct {
	mask uint64
	recs []kFanRec
}

// an info record: the directory and an entry name
type kFanRec struct {
	typ  byte
	dir  *kNode
	name string
}

// struct fanotify_event_metadata, as unix.FanotifyEventMetadata reads it
type kFanMeta struct {
	Event_len    uint32
	Vers         uint8
	Reserved     uint8
	Metadata_len uint16
	Mask         uint64
	Fd           int32
	Pid          int32
}

func kRemoveNode(ns []*kNode, n *kNode) []*kNode {
	for i, x := range ns {
		if x == n {
			return append(ns[:i:i], ns[i+1:]...)
		}
	}
	return ns
}

// the file handle of a node: its inode number
func kHandle(n *kNode) []byte {
	h := make([]byte, 8)
	for i := range h {
		h[i] = byte(n.ino >> (8 * i))
	}
	return h
}

func (k *kKernel) fanMark(fd int, flags uint, mask uint64, dirfd int, pathp uintptr) Errno {
	f, e := k.file(fd)
	if e != 0 {
		return e
	}
	if f.fanotify == nil {
		return EINVAL
	}
	g := f.fanotify
	op := flags & (kFanMarkAdd | kFanMarkRemove | kFanMarkFlush)
	if op != kFanMarkAdd && op != kFanMarkRemove && op != kFanMarkFlush || mask&^kFanAllowed != 0 {
		return EINVAL
	}
	if op == kFanMarkFlush {
		for _, n := range g.marked {
			for i, m := range n.marks {
				if m.g == g {
					n.marks = append(n.marks[:i:i], n.marks[i+1:]...)
					break
				}
			}
		}
		g.marked = nil
		return 0
	}
	var n *kNode
	if kNil(pathp) {
		f2, e := k.file(dirfd)
		if e != 0 {
			return e
		}
		n = f2.node
	} else {
		_, _, n, e = k.lookup(dirfd, kCString(pathp), flags&kFanMarkDontFoll == 0)
		if e == 0 && n == nil {
			e = ENOENT
		}
		if e != 0 {
			return e
		}
	}
	if n == nil {
		return EINVAL
	}
	if flags&kFanMarkOnlydir != 0 && !n.isDir() {
		return ENOTDIR
	}
	for i, m := range n.marks {
		if m.g != g {
			continue
		}
		if op == kFanMarkAdd {
			m.mask |= mask
			return 0
		}
		m.mask &^= mask
		if m.mask&^(kFanOndir|kFanEventOnChild) == 0 {
			n.marks = append(n.marks[:i:i], n.marks[i+1:]...)
			g.marked = kRemoveNode(g.marked, n)
		}
		return 0
	}
	if op == kFanMarkRemove {
		return ENOENT
	}
	n.marks = append(n.marks, &kFanMark{g: g, mask: mask})
	g.marked = append(g.marked, n)
	return 0
}

// queues an event for the marks on n that want it
func (k *kKernel) fanQueue(n *kNode, mask uint32, isdir bool, onChild bool, recs ...kFanRec) {
	if n == nil {
		return
	}
	for _, m := range n.marks {
		if onChild && m.mask&kFanEventOnChild == 0 {
			continue
		}
		bits := uint64(mask) & m.mask
		if bits == 0 {
			continue
		}
		if isdir {
			if m.mask&kFanOndir == 0 {
				continue
			}
			bits |= kFanOndir
		}
		m.g.events = append(m.g.events, kFanEvent{mask: bits, recs: recs})
		tststWake()
	}
}

// an event about entry name of dir (created, deleted, moved)
func (k *kKernel) fanDirent(dir *kNode, name string, child *kNode, mask uint32) {
	k.fanQueue(dir, mask&kFanDirent, child != nil && child.isDir(), false, kFanRec{kFanInfoDfidName, dir, name})
}

// an event on n itself (modified, attributes): to its marks and to its
// directory's marks for events on children
func (k *kKernel) fanInode(dir *kNode, name string, n *kNode, mask uint32) {
	if n.isDir() {
		k.fanQueue(n, mask, true, false, kFanRec{kFanInfoDfidName, n, "."})
	} else if dir != nil {
		k.fanQueue(n, mask, false, false, kFanRec{kFanInfoDfidName, dir, name})
	}
	if dir != nil && dir != n {
		k.fanQueue(dir, mask, n.isDir(), true, kFanRec{kFanInfoDfidName, dir, name})
	}
}

// deleted or moved itself
func (k *kKernel) fanSelf(n *kNode, mask uint32) {
	if n.isDir() {
		k.fanQueue(n, mask, true, false, kFanRec{kFanInfoDfidName, n, "."})
	} else if n.parent != nil {
		k.fanQueue(n, mask, false, false, kFanRec{kFanInfoDfidName, n.parent, n.name})
	}
}

// FAN_RENAME: one event naming both places, for marks on either directory
func (k *kKernel) fanRename(od *kNode, oname string, nd *kNode, nname string, n *kNode) {
	seen := map[*kFanotify]bool{}
	for _, d := range []*kNode{od, nd} {
		for _, m := range d.marks {
			if m.mask&kFanRename == 0 || seen[m.g] {
				continue
			}
			bits := uint64(kFanRename)
			if n.isDir() {
				if m.mask&kFanOndir == 0 {
					continue
				}
				bits |= kFanOndir
			}
			seen[m.g] = true
			m.g.events = append(m.g.events, kFanEvent{mask: bits, recs: []kFanRec{
				{kFanInfoOldDfidName, od, oname}, {kFanInfoNewDfidName, nd, nname}}})
			tststWake()
		}
	}
}

// struct fanotify_event_info_fid with the handle and name, as bytes
func kFanRecord(r kFanRec) []byte {
	l := 4 + 8 + 8 + 8 + len(r.name) + 1
	l = (l + 3) / 4 * 4
	b := make([]byte, l)
	b[0] = r.typ
	b[2], b[3] = byte(l), byte(l>>8)
	b[12] = 8 // handle_bytes
	b[16] = 1 // handle_type
	copy(b[20:], kHandle(r.dir))
	copy(b[28:], r.name)
	return b
}

func (k *kKernel) fanRead(f *kFile, buf []byte) (int, Errno) {
	g := f.fanotify
	timeout := int64(-1)
	if f.flags&O_NONBLOCK != 0 {
		timeout = 0
	}
	if !kBlock(func() bool { return len(g.events) > 0 }, timeout) {
		return 0, EAGAIN
	}
	n := 0
	for len(g.events) > 0 {
		ev := g.events[0]
		var info []byte
		for _, r := range ev.recs {
			info = append(info, kFanRecord(r)...)
		}
		total := 24 + len(info)
		if n+total > len(buf) {
			if n == 0 {
				return 0, EINVAL
			}
			break
		}
		rec := buf[n : n+total]
		for i := range rec {
			rec[i] = 0
		}
		// the metadata as seven cells (see the top), the records as bytes
		*(*kFanMeta)(unsafe.Pointer(&rec[0])) = kFanMeta{Event_len: uint32(total), Vers: 3, Metadata_len: 24, Mask: ev.mask, Fd: -1, Pid: 1000}
		copy(rec[24:], info)
		n += total
		g.events = g.events[1:]
	}
	return n, 0
}
