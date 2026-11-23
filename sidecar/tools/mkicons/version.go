package main

import (
	"bytes"
	"encoding/binary"
	"strconv"
	"strings"
	"unicode/utf16"
)

const rtVersion = 16

// versionResource is a VS_VERSIONINFO block: the fixed numeric version
// (what Windows compares) and the strings Explorer's Details tab shows.
func versionResource(version, fileName, description string) resource {
	nums := parseVersion(version)
	var fixed bytes.Buffer
	binary.Write(&fixed, binary.LittleEndian, []uint32{
		0xFEEF04BD, 0x00010000, // signature, struct version
		nums[0]<<16 | nums[1], nums[2]<<16 | nums[3], // file version MS / LS
		nums[0]<<16 | nums[1], nums[2]<<16 | nums[3], // product version MS / LS
		0x3F, 0, // flags mask, flags
		0x00040004, // VOS_NT_WINDOWS32
		1,          // VFT_APP
		0, 0, 0,    // subtype, date
	})
	strs := [][2]string{
		{"CompanyName", "Bromure"},
		{"FileDescription", description},
		{"FileVersion", version},
		{"InternalName", strings.TrimSuffix(fileName, ".exe")},
		{"LegalCopyright", "Bromure"},
		{"OriginalFilename", fileName},
		{"ProductName", "Bromure Sidecar"},
		{"ProductVersion", version},
	}
	var table []byte
	for _, s := range strs {
		table = append(table, block(s[0], 1, utf16z(s[1]))...)
	}
	stringTable := blockWithValue("040904b0", 1, nil, table) // en-US, Unicode
	stringFileInfo := blockWithValue("StringFileInfo", 1, nil, stringTable)
	var translation bytes.Buffer
	binary.Write(&translation, binary.LittleEndian, []uint16{0x0409, 0x04b0})
	varFileInfo := blockWithValue("VarFileInfo", 1, nil, block("Translation", 0, translation.Bytes()))
	children := append(append([]byte{}, stringFileInfo...), varFileInfo...)
	root := blockWithValue("VS_VERSION_INFO", 0, fixed.Bytes(), children)
	return resource{typ: rtVersion, id: 1, data: root}
}

func parseVersion(v string) [4]uint32 {
	v = strings.TrimPrefix(v, "v")
	if i := strings.IndexAny(v, "-+ "); i >= 0 {
		v = v[:i]
	}
	var out [4]uint32
	for i, p := range strings.SplitN(v, ".", 4) {
		n, _ := strconv.Atoi(p)
		out[i] = uint32(n)
	}
	return out
}

func utf16z(s string) []byte {
	u := append(utf16.Encode([]rune(s)), 0)
	b := make([]byte, 2*len(u))
	for i, c := range u {
		binary.LittleEndian.PutUint16(b[2*i:], c)
	}
	return b
}

func pad4(b []byte) []byte {
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return b
}

// block is one version-info node whose value is text (typ 1, length in
// WORDs) or binary (typ 0, length in bytes), without children.
func block(key string, typ uint16, value []byte) []byte {
	return blockWithValue(key, typ, value, nil)
}

func blockWithValue(key string, typ uint16, value, children []byte) []byte {
	head := make([]byte, 6)
	body := pad4(append(head, utf16z(key)...))
	valueLen := len(value)
	if typ == 1 {
		valueLen = len(value) / 2
	}
	body = pad4(append(body, value...))
	body = append(body, children...)
	binary.LittleEndian.PutUint16(body[0:], uint16(len(body)))
	binary.LittleEndian.PutUint16(body[2:], uint16(valueLen))
	binary.LittleEndian.PutUint16(body[4:], typ)
	return pad4(body)
}
