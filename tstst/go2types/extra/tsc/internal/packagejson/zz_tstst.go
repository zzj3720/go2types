package packagejson

import (
	"errors"

	"github.com/microsoft/TypeScript/tsc/internal/collections"
	"github.com/microsoft/TypeScript/tsc/internal/json"
)

// tststParse is Parse without encoding/json, which needs reflection: the
// text is parsed into a tree first (json.TststParse), then the fields are taken from it the way
// json.Unmarshal fills them (later duplicate keys win, unknown keys are
// ignored, a value of the wrong JSON type leaves its field invalid).
func tststParse(data []byte) (Fields, error) {
	v, err := json.TststParse(data)
	if err != nil {
		return Fields{}, err
	}
	if v.Kind != 'o' {
		return Fields{}, errors.New("cannot unmarshal JSON " + v.TypeName() + " into package.json")
	}
	var f Fields
	for i, k := range v.Keys {
		e := v.Vals[i]
		switch k {
		case "name":
			f.Name = tststExpectedString(e)
		case "version":
			f.Version = tststExpectedString(e)
		case "type":
			f.Type = tststExpectedString(e)
		case "tsconfig":
			f.TSConfig = tststExpectedString(e)
		case "main":
			f.Main = tststExpectedString(e)
		case "types":
			f.Types = tststExpectedString(e)
		case "typings":
			f.Typings = tststExpectedString(e)
		case "typesVersions":
			f.TypesVersions = tststJSONValue(e)
		case "imports":
			f.Imports = tststExportsOrImports(e)
		case "exports":
			f.Exports = tststExportsOrImports(e)
		case "dependencies":
			f.Dependencies = tststExpectedMap(e)
		case "devDependencies":
			f.DevDependencies = tststExpectedMap(e)
		case "peerDependencies":
			f.PeerDependencies = tststExpectedMap(e)
		case "optionalDependencies":
			f.OptionalDependencies = tststExpectedMap(e)
		case "typescript":
			if e.Kind == 'o' {
				for j, k2 := range e.Keys {
					if k2 == "contentMapper" {
						f.ContentMapper = tststContentMapper(e.Vals[j])
					}
				}
			}
		}
	}
	return f, nil
}

func tststExpectedString(v *json.TststValue) Expected[string] {
	if v.Kind == 'n' {
		return Expected[string]{Null: true, actualJSONType: "null"}
	}
	e := Expected[string]{actualJSONType: v.TypeName()}
	if v.Kind == 's' {
		e.Valid, e.Value = true, v.S
	}
	return e
}

func tststExpectedMap(v *json.TststValue) Expected[map[string]string] {
	if v.Kind == 'n' {
		return Expected[map[string]string]{Null: true, actualJSONType: "null"}
	}
	e := Expected[map[string]string]{actualJSONType: v.TypeName()}
	if v.Kind == 'o' {
		m := make(map[string]string, len(v.Keys))
		e.Valid = true
		for i, k := range v.Keys {
			if v.Vals[i].Kind != 's' {
				e.Valid = false
				break
			}
			m[k] = v.Vals[i].S
		}
		e.Value = m
	}
	return e
}

func tststExpectedStrings(v *json.TststValue) Expected[[]string] {
	if v.Kind == 'n' {
		return Expected[[]string]{Null: true, actualJSONType: "null"}
	}
	e := Expected[[]string]{actualJSONType: v.TypeName()}
	if v.Kind == 'a' {
		e.Valid = true
		for _, x := range v.Arr {
			if x.Kind != 's' {
				e.Valid = false
				break
			}
			e.Value = append(e.Value, x.S)
		}
	}
	return e
}

func tststContentMapper(v *json.TststValue) Expected[ContentMapperFields] {
	if v.Kind == 'n' {
		return Expected[ContentMapperFields]{Null: true, actualJSONType: "null"}
	}
	e := Expected[ContentMapperFields]{actualJSONType: v.TypeName()}
	if v.Kind != 'o' {
		return e
	}
	e.Valid = true
	for i, k := range v.Keys {
		x := v.Vals[i]
		switch k {
		case "exec":
			e.Value.Exec = tststExpectedStrings(x)
		case "compilerOptions":
			e.Value.CompilerOptions = tststExpectedStrings(x)
		case "dynamicConfig":
			if x.Kind == 'n' {
				e.Value.DynamicConfig = Expected[bool]{Null: true, actualJSONType: "null"}
			} else {
				e.Value.DynamicConfig = Expected[bool]{actualJSONType: x.TypeName(), Valid: x.Kind == 't', Value: x.B}
			}
		}
	}
	return e
}

// the Go value encoding/json gives a scalar when unmarshaled into any
func tststScalar(v *json.TststValue) (JSONValueType, any) {
	switch v.Kind {
	case 'n':
		return JSONValueTypeNull, nil
	case 's':
		return JSONValueTypeString, v.S
	case 't':
		return JSONValueTypeBoolean, v.B
	}
	return JSONValueTypeNumber, v.D
}

func tststJSONValue(v *json.TststValue) JSONValue {
	switch v.Kind {
	case 'a':
		elems := make([]JSONValue, 0, len(v.Arr))
		for _, x := range v.Arr {
			elems = append(elems, tststJSONValue(x))
		}
		return JSONValue{Type: JSONValueTypeArray, Value: elems}
	case 'o':
		var m collections.OrderedMap[string, JSONValue]
		for i, k := range v.Keys {
			m.Set(k, tststJSONValue(v.Vals[i]))
		}
		return JSONValue{Type: JSONValueTypeObject, Value: &m}
	}
	t, x := tststScalar(v)
	return JSONValue{Type: t, Value: x}
}

func tststExportsOrImports(v *json.TststValue) ExportsOrImports {
	switch v.Kind {
	case 'a':
		var elems []ExportsOrImports
		for _, x := range v.Arr {
			elems = append(elems, tststExportsOrImports(x))
		}
		return ExportsOrImports{JSONValue: JSONValue{Type: JSONValueTypeArray, Value: elems}}
	case 'o':
		var m collections.OrderedMap[string, ExportsOrImports]
		for i, k := range v.Keys {
			m.Set(k, tststExportsOrImports(v.Vals[i]))
		}
		return ExportsOrImports{JSONValue: JSONValue{Type: JSONValueTypeObject, Value: &m}}
	}
	t, x := tststScalar(v)
	return ExportsOrImports{JSONValue: JSONValue{Type: t, Value: x}}
}
