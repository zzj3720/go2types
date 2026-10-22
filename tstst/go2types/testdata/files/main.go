package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func check(what string, err error) {
	if err != nil {
		fmt.Println(what, "error:", err)
	}
}

func main() {
	dir, err := os.MkdirTemp("", "g2t-files")
	check("mkdirtemp", err)
	defer os.RemoveAll(dir)

	a := filepath.Join(dir, "a.txt")
	check("write", os.WriteFile(a, []byte("hello\n"), 0o644))
	b, err := os.ReadFile(a)
	check("read", err)
	fmt.Printf("%q\n", b)
	st, err := os.Stat(a)
	check("stat", err)
	fmt.Println(st.Name(), st.Size(), st.IsDir(), st.Mode().Perm(), st.Mode().IsRegular())

	f, err := os.OpenFile(a, os.O_APPEND|os.O_WRONLY, 0)
	check("open append", err)
	fmt.Fprintf(f, "world %d\n", 42)
	check("close", f.Close())
	b, _ = os.ReadFile(a)
	fmt.Printf("%q\n", b)

	f, _ = os.Open(a)
	buf := make([]byte, 3)
	n, _ := f.Read(buf)
	off, _ := f.Seek(1, io.SeekCurrent)
	rest, _ := io.ReadAll(f)
	f.Close()
	fmt.Println(n, string(buf), off, strings.TrimSpace(string(rest)))

	check("mkdirall", os.MkdirAll(filepath.Join(dir, "sub", "x", "y"), 0o755))
	check("mkdirall again", os.MkdirAll(filepath.Join(dir, "sub", "x"), 0o755))
	check("write b", os.WriteFile(filepath.Join(dir, "sub", "b.txt"), []byte("b"), 0o600))
	err = os.Mkdir(filepath.Join(dir, "sub"), 0o755)
	fmt.Println("mkdir existing:", errors.Is(err, fs.ErrExist))

	entries, err := os.ReadDir(dir)
	check("readdir", err)
	for _, e := range entries {
		fmt.Println("entry", e.Name(), e.IsDir(), e.Type().IsRegular())
	}

	check("rename", os.Rename(a, filepath.Join(dir, "sub", "a2.txt")))
	_, err = os.Stat(a)
	fmt.Println("old name gone:", errors.Is(err, fs.ErrNotExist))

	err = os.Remove(filepath.Join(dir, "sub"))
	fmt.Println("remove non-empty fails:", err != nil)

	check("symlink", os.Symlink("sub/b.txt", filepath.Join(dir, "link")))
	target, err := os.Readlink(filepath.Join(dir, "link"))
	check("readlink", err)
	lst, _ := os.Lstat(filepath.Join(dir, "link"))
	st, _ = os.Stat(filepath.Join(dir, "link"))
	fmt.Println("link", target, lst.Mode()&fs.ModeSymlink != 0, st.Mode().IsRegular(), st.Size())
	b, _ = os.ReadFile(filepath.Join(dir, "link"))
	fmt.Println("through link:", string(b))

	var walked []string
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(dir, p)
		walked = append(walked, fmt.Sprintf("%s:%v", filepath.ToSlash(rel), d.IsDir()))
		return nil
	})
	fmt.Println(strings.Join(walked, " "))

	tf, err := os.CreateTemp(dir, "tmp-*.json")
	check("createtemp", err)
	fmt.Println("temp:", strings.HasPrefix(filepath.Base(tf.Name()), "tmp-"), strings.HasSuffix(tf.Name(), ".json"))
	tf.WriteString("{}")
	tf.Close()

	r, w, err := os.Pipe()
	check("pipe", err)
	go func() {
		for i := 0; i < 3; i++ {
			fmt.Fprintf(w, "line %d\n", i)
		}
		w.Close()
	}()
	all, _ := io.ReadAll(r)
	r.Close()
	fmt.Printf("pipe: %q\n", all)

	wd, _ := os.Getwd()
	check("chdir", os.Chdir(filepath.Join(dir, "sub")))
	b, err = os.ReadFile("b.txt")
	check("read relative", err)
	fmt.Println("relative:", string(b))
	cwd, _ := os.Getwd()
	fmt.Println("cwd:", filepath.Base(cwd))
	os.Chdir(wd)

	check("chmod", os.Chmod(filepath.Join(dir, "sub", "b.txt"), 0o640))
	st, _ = os.Stat(filepath.Join(dir, "sub", "b.txt"))
	fmt.Println("mode:", st.Mode())

	check("truncate", os.Truncate(filepath.Join(dir, "sub", "a2.txt"), 2))
	b, _ = os.ReadFile(filepath.Join(dir, "sub", "a2.txt"))
	fmt.Printf("truncated: %q\n", b)

	_, err = os.Open(filepath.Join(dir, "nope"))
	fmt.Println("open missing:", errors.Is(err, fs.ErrNotExist))
	var pe *fs.PathError
	fmt.Println("path error:", errors.As(err, &pe), pe.Op, filepath.Base(pe.Path), pe.Err)

	names, _ := filepath.Glob(filepath.Join(dir, "sub", "*.txt"))
	for i := range names {
		names[i] = filepath.Base(names[i])
	}
	sort.Strings(names)
	fmt.Println("glob:", names)

	check("removeall", os.RemoveAll(filepath.Join(dir, "sub")))
	_, err = os.Stat(filepath.Join(dir, "sub"))
	fmt.Println("removed:", errors.Is(err, fs.ErrNotExist))
	entries, _ = os.ReadDir(dir)
	for _, e := range entries {
		fmt.Println("left", e.Name()[:4])
	}
}
