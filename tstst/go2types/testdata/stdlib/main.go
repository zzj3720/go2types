package main

import (
	"errors"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type byLen []string

func (b byLen) Len() int           { return len(b) }
func (b byLen) Less(i, j int) bool { return len(b[i]) < len(b[j]) }
func (b byLen) Swap(i, j int)      { b[i], b[j] = b[j], b[i] }

var errNotFound = errors.New("not found")

func find(xs []string, s string) (int, error) {
	for i, x := range xs {
		if x == s {
			return i, nil
		}
	}
	return -1, errNotFound
}

type Point struct{ X, Y int }

func (p Point) String() string {
	return "(" + strconv.Itoa(p.X) + "," + strconv.Itoa(p.Y) + ")"
}

type Stringer interface{ String() string }

func main() {
	s := "The quick brown fox jumps over the lazy dog"
	words := strings.Fields(s)
	println(len(words), strings.ToUpper(words[1]), strings.Contains(s, "fox"), strings.Index(s, "lazy"))
	println(strings.Join(words[:3], "-"), strings.Repeat("ab", 3), strings.TrimSpace("  x  "))
	println(strings.HasPrefix(s, "The"), strings.HasSuffix(s, "dog"), strings.Count(s, "o"))
	println(strings.Replace(s, "o", "0", 2), strings.LastIndex(s, "o"))
	parts := strings.Split("a,b,,c", ",")
	println(len(parts), parts[3])
	var sb strings.Builder
	for i := 0; i < 5; i++ {
		sb.WriteString(strconv.Itoa(i * i))
		sb.WriteByte(';')
	}
	sb.WriteRune('é')
	println(sb.String(), sb.Len())
	n, err := strconv.Atoi("12345")
	println(n+1, err == nil)
	_, err = strconv.Atoi("12x")
	println(err != nil)
	f, _ := strconv.ParseFloat("3.25", 64)
	println(strconv.FormatFloat(f*2, 'g', -1, 64), strconv.Quote("hi\n\"there\""))
	println(strconv.FormatInt(-255, 16), strconv.FormatUint(1<<63, 10))
	xs := []int{5, 2, 8, 1, 9, 3}
	sort.Ints(xs)
	println(xs[0], xs[1], xs[5])
	ws := byLen{"ccc", "a", "bb", "dddd"}
	sort.Sort(ws)
	println(ws[0], ws[3])
	ys := []string{"pear", "apple", "fig"}
	slices.Sort(ys)
	println(ys[0], ys[1], ys[2], slices.Contains(ys, "fig"), slices.Index(ys, "pear"))
	slices.SortFunc(xs, func(a, b int) int { return b - a })
	println(xs[0], xs[5])
	i, err := find(ys, "kiwi")
	println(i, err.Error(), errors.Is(err, errNotFound))
	println(utf8.RuneCountInString("héllo"), unicode.IsUpper('Q'), unicode.IsLetter('é'), unicode.ToLower('Ä') == 'ä')
	var st Stringer = Point{1, 2}
	println(st.String())
	m := map[int]string{}
	for i := 0; i < 20; i++ {
		m[i] = strconv.Itoa(i)
	}
	keys := make([]int, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	println(len(keys), keys[19], m[13])
}
