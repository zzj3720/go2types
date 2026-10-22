package sourcemap

import (
	"errors"
	"strconv"

	"github.com/microsoft/TypeScript/tsc/internal/json"
)

// TststJSON is json.Marshal of the source map without reflection.
func (m *RawSourceMap) TststJSON() []byte {
	strs := func(b []byte, ss []string) []byte {
		b = append(b, '[')
		for i, s := range ss {
			if i > 0 {
				b = append(b, ',')
			}
			b = json.TststAppendString(b, s)
		}
		return append(b, ']')
	}
	b := []byte(`{"version":`)
	b = strconv.AppendInt(b, int64(m.Version), 10)
	b = append(b, `,"file":`...)
	b = json.TststAppendString(b, m.File)
	if m.SourceRoot != "" {
		b = append(b, `,"sourceRoot":`...)
		b = json.TststAppendString(b, m.SourceRoot)
	}
	b = append(b, `,"sources":`...)
	b = strs(b, m.Sources)
	b = append(b, `,"names":`...)
	b = strs(b, m.Names)
	b = append(b, `,"mappings":`...)
	b = json.TststAppendString(b, m.Mappings)
	if m.SourcesContent != nil {
		b = append(b, `,"sourcesContent":[`...)
		for i, s := range m.SourcesContent {
			if i > 0 {
				b = append(b, ',')
			}
			if s == nil {
				b = append(b, "null"...)
			} else {
				b = json.TststAppendString(b, *s)
			}
		}
		b = append(b, ']')
	}
	return append(b, '}')
}

// TststUnmarshalJSON is json.Unmarshal into the source map without
// reflection: unknown fields are ignored, null leaves a field zero.
func (m *RawSourceMap) TststUnmarshalJSON(data []byte) error {
	v, err := json.TststParse(data)
	if err != nil {
		return err
	}
	if v.Kind != 'o' {
		return errors.New("cannot unmarshal JSON " + v.TypeName() + " into a source map")
	}
	strs := func(x *json.TststValue) ([]string, error) {
		if x.Kind == 'n' {
			return nil, nil
		}
		if x.Kind != 'a' {
			return nil, errors.New("expected an array of strings")
		}
		out := make([]string, 0, len(x.Arr))
		for _, e := range x.Arr {
			if e.Kind != 's' {
				return nil, errors.New("expected a string")
			}
			out = append(out, e.S)
		}
		return out, nil
	}
	str := func(x *json.TststValue) (string, error) {
		switch x.Kind {
		case 'n':
			return "", nil
		case 's':
			return x.S, nil
		}
		return "", errors.New("expected a string")
	}
	for i, k := range v.Keys {
		x := v.Vals[i]
		var err error
		switch k {
		case "version":
			if x.Kind == 'd' {
				m.Version = int(x.D)
			} else if x.Kind != 'n' {
				err = errors.New("expected a number")
			}
		case "file":
			m.File, err = str(x)
		case "sourceRoot":
			m.SourceRoot, err = str(x)
		case "sources":
			m.Sources, err = strs(x)
		case "names":
			m.Names, err = strs(x)
		case "mappings":
			m.Mappings, err = str(x)
		case "sourcesContent":
			if x.Kind == 'a' {
				m.SourcesContent = make([]*string, 0, len(x.Arr))
				for _, e := range x.Arr {
					if e.Kind == 's' {
						s := e.S
						m.SourcesContent = append(m.SourcesContent, &s)
					} else {
						m.SourcesContent = append(m.SourcesContent, nil)
					}
				}
			}
		}
		if err != nil {
			return err
		}
	}
	return nil
}
