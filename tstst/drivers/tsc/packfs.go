package main

import (
	"io"
	"io/fs"
	"sort"
	"strings"
	"time"
)

// packFS is the read-only file system of the input's files, with its
// directories indexed once. (vfstest's MapFS, on testing/fstest, finds a
// directory or a missing path by going over every file: module resolution
// stats thousands of paths, which made the check of a project with 10000
// files mostly that.)
type packFS struct {
	files map[string]string        // path (no leading /) -> contents
	dirs  map[string][]fs.DirEntry // path ("." for the root) -> entries, sorted
}

var packTime = time.Unix(0, 0)

func newPackFS(files map[string]string) *packFS {
	p := &packFS{files: map[string]string{}, dirs: map[string][]fs.DirEntry{".": nil}}
	children := map[string]map[string]bool{".": {}}
	for name, data := range files {
		name = strings.TrimPrefix(name, "/")
		p.files[name] = data
		child := name
		for {
			dir := "."
			if i := strings.LastIndexByte(child, '/'); i >= 0 {
				dir = child[:i]
			}
			seen := children[dir] != nil
			if !seen {
				children[dir] = map[string]bool{}
			}
			children[dir][child] = true
			if seen || dir == "." {
				break
			}
			child = dir
		}
	}
	for dir, names := range children {
		var entries []fs.DirEntry
		for name := range names {
			entries = append(entries, fs.FileInfoToDirEntry(p.info(name)))
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		p.dirs[dir] = entries
	}
	return p
}

type packInfo struct {
	name string
	size int64
	dir  bool
}

func (i *packInfo) Name() string { return i.name }
func (i *packInfo) Size() int64  { return i.size }
func (i *packInfo) Mode() fs.FileMode {
	if i.dir {
		return fs.ModeDir | 0o555
	}
	return 0o444
}
func (i *packInfo) ModTime() time.Time { return packTime }
func (i *packInfo) IsDir() bool        { return i.dir }
func (i *packInfo) Sys() any           { return nil }

func (p *packFS) info(name string) *packInfo {
	base := name
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		base = name[i+1:]
	}
	if data, ok := p.files[name]; ok {
		return &packInfo{name: base, size: int64(len(data))}
	}
	return &packInfo{name: base, dir: true}
}

func (p *packFS) exists(name string) bool {
	if _, ok := p.files[name]; ok {
		return true
	}
	_, ok := p.dirs[name]
	return ok
}

func (p *packFS) Stat(name string) (fs.FileInfo, error) {
	if !p.exists(name) {
		return nil, &fs.PathError{Op: "stat", Path: name, Err: fs.ErrNotExist}
	}
	return p.info(name), nil
}

func (p *packFS) ReadFile(name string) ([]byte, error) {
	data, ok := p.files[name]
	if !ok {
		return nil, &fs.PathError{Op: "read", Path: name, Err: fs.ErrNotExist}
	}
	return []byte(data), nil
}

func (p *packFS) ReadDir(name string) ([]fs.DirEntry, error) {
	entries, ok := p.dirs[name]
	if !ok {
		return nil, &fs.PathError{Op: "readdir", Path: name, Err: fs.ErrNotExist}
	}
	return entries, nil
}

func (p *packFS) Open(name string) (fs.File, error) {
	if data, ok := p.files[name]; ok {
		return &packFile{info: p.info(name), r: strings.NewReader(data)}, nil
	}
	if entries, ok := p.dirs[name]; ok {
		return &packFile{info: p.info(name), entries: entries}, nil
	}
	return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
}

type packFile struct {
	info    *packInfo
	r       *strings.Reader
	entries []fs.DirEntry
}

func (f *packFile) Stat() (fs.FileInfo, error) { return f.info, nil }
func (f *packFile) Close() error               { return nil }
func (f *packFile) Read(b []byte) (int, error) {
	if f.r == nil {
		return 0, &fs.PathError{Op: "read", Path: f.info.name, Err: fs.ErrInvalid}
	}
	return f.r.Read(b)
}
func (f *packFile) ReadDir(n int) ([]fs.DirEntry, error) {
	if n <= 0 {
		e := f.entries
		f.entries = nil
		return e, nil
	}
	if len(f.entries) == 0 {
		return nil, io.EOF
	}
	if n > len(f.entries) {
		n = len(f.entries)
	}
	e := f.entries[:n]
	f.entries = f.entries[n:]
	return e, nil
}
