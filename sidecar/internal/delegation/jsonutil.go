package delegation

import (
	"bytes"
	"encoding/json"
)

// orderedField / ordered: a JSON object whose keys keep their order (the
// replies read like the Swift ones in a log), without HTML escaping.
type orderedField struct {
	K string
	V any
}

type ordered []orderedField

func (o ordered) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, f := range o {
		if i > 0 {
			b.WriteByte(',')
		}
		k, err := marshalNoHTML(f.K)
		if err != nil {
			return nil, err
		}
		b.Write(k)
		b.WriteByte(':')
		v, err := marshalNoHTML(f.V)
		if err != nil {
			return nil, err
		}
		b.Write(v)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

func marshalNoHTML(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

func encodeOrdered(fields []orderedField) []byte {
	out, err := marshalNoHTML(ordered(fields))
	if err != nil {
		return []byte("{}")
	}
	return out
}
