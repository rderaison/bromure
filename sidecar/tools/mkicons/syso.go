package main

// A minimal Windows resource object (.syso, COFF with one .rsrc section)
// that `go build` links into an executable: the app icon (RT_ICON +
// RT_GROUP_ICON) and the application manifest (RT_MANIFEST). Written here
// rather than by an external resource compiler, so building needs nothing
// but Go.

import (
	"bytes"
	"encoding/binary"
	"sort"
)

const (
	rtIcon      = 3
	rtGroupIcon = 14
	rtManifest  = 24
	langNeutral = 0x0409 // en-US, what Windows looks up first
)

// resource is one leaf: type / id / language → data.
type resource struct {
	typ, id uint16
	data    []byte
}

// iconResources splits an .ico into RT_ICON entries and its RT_GROUP_ICON.
func iconResources(ico []byte, groupID uint16) []resource {
	n := int(binary.LittleEndian.Uint16(ico[4:]))
	var out []resource
	var grp bytes.Buffer
	binary.Write(&grp, binary.LittleEndian, []uint16{0, 1, uint16(n)})
	for i := 0; i < n; i++ {
		e := ico[6+16*i : 6+16*i+16]
		size := binary.LittleEndian.Uint32(e[8:])
		off := binary.LittleEndian.Uint32(e[12:])
		id := uint16(i + 1)
		out = append(out, resource{typ: rtIcon, id: id, data: ico[off : off+size]})
		grp.Write(e[:12]) // width, height, colors, reserved, planes, bitcount, bytes
		binary.Write(&grp, binary.LittleEndian, id)
	}
	out = append(out, resource{typ: rtGroupIcon, id: groupID, data: grp.Bytes()})
	return out
}

// Machine types.
const (
	machineAMD64 = 0x8664
	machineARM64 = 0xAA64
)

// syso builds the COFF object for machine.
func syso(machine uint16, res []resource) []byte {
	sort.Slice(res, func(i, j int) bool {
		if res[i].typ != res[j].typ {
			return res[i].typ < res[j].typ
		}
		return res[i].id < res[j].id
	})
	// Group by type.
	var types []uint16
	byType := map[uint16][]resource{}
	for _, r := range res {
		if _, ok := byType[r.typ]; !ok {
			types = append(types, r.typ)
		}
		byType[r.typ] = append(byType[r.typ], r)
	}
	// Layout: root dir, type dirs, id dirs (one language each), data
	// entries, then the data itself (8-aligned).
	dirSize := func(entries int) int { return 16 + 8*entries }
	off := dirSize(len(types))
	typeDirOff := map[uint16]int{}
	for _, t := range types {
		typeDirOff[t] = off
		off += dirSize(len(byType[t]))
	}
	langDirOff := make([]int, len(res))
	i := 0
	for _, t := range types {
		for range byType[t] {
			langDirOff[i] = off
			off += dirSize(1)
			i++
		}
	}
	dataEntryOff := make([]int, len(res))
	for i := range res {
		dataEntryOff[i] = off
		off += 16
	}
	dataOff := make([]int, len(res))
	for i, r := range res {
		off = (off + 7) &^ 7
		dataOff[i] = off
		off += len(r.data)
	}
	sec := make([]byte, (off+7)&^7)
	putDir := func(at, entries int) {
		// Characteristics, TimeDateStamp, Major, Minor, NamedEntries, IdEntries.
		binary.LittleEndian.PutUint16(sec[at+14:], uint16(entries))
	}
	putEntry := func(at int, id uint16, target int, isDir bool) {
		binary.LittleEndian.PutUint32(sec[at:], uint32(id))
		v := uint32(target)
		if isDir {
			v |= 0x80000000
		}
		binary.LittleEndian.PutUint32(sec[at+4:], v)
	}
	putDir(0, len(types))
	i = 0
	for ti, t := range types {
		putEntry(16+8*ti, t, typeDirOff[t], true)
		putDir(typeDirOff[t], len(byType[t]))
		for ri, r := range byType[t] {
			putEntry(typeDirOff[t]+16+8*ri, r.id, langDirOff[i], true)
			putDir(langDirOff[i], 1)
			putEntry(langDirOff[i]+16, langNeutral, dataEntryOff[i], false)
			// Data entry: RVA (relocated), size, codepage, reserved.
			binary.LittleEndian.PutUint32(sec[dataEntryOff[i]:], uint32(dataOff[i]))
			binary.LittleEndian.PutUint32(sec[dataEntryOff[i]+4:], uint32(len(r.data)))
			copy(sec[dataOff[i]:], r.data)
			i++
		}
	}
	// COFF: header (20), one section header (40), the section, its
	// relocations (one ADDR32NB per data entry's RVA), the symbol table
	// (the section symbol + aux record), an empty string table.
	relocType := uint16(3) // IMAGE_REL_AMD64_ADDR32NB
	if machine == machineARM64 {
		relocType = 2 // IMAGE_REL_ARM64_ADDR32NB
	}
	secStart := 20 + 40
	relocStart := secStart + len(sec)
	symStart := relocStart + 10*len(res)
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, struct {
		Machine              uint16
		NumberOfSections     uint16
		TimeDateStamp        uint32
		PointerToSymbolTable uint32
		NumberOfSymbols      uint32
		SizeOfOptionalHeader uint16
		Characteristics      uint16
	}{machine, 1, 0, uint32(symStart), 2, 0, 0})
	var name [8]byte
	copy(name[:], ".rsrc")
	binary.Write(&b, binary.LittleEndian, struct {
		Name                 [8]byte
		VirtualSize          uint32
		VirtualAddress       uint32
		SizeOfRawData        uint32
		PointerToRawData     uint32
		PointerToRelocations uint32
		PointerToLinenumbers uint32
		NumberOfRelocations  uint16
		NumberOfLinenumbers  uint16
		Characteristics      uint32
	}{name, 0, 0, uint32(len(sec)), uint32(secStart), uint32(relocStart), 0, uint16(len(res)), 0,
		0x40000040}) // IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ
	b.Write(sec)
	for i := range res {
		binary.Write(&b, binary.LittleEndian, uint32(dataEntryOff[i])) // VirtualAddress
		binary.Write(&b, binary.LittleEndian, uint32(0))               // symbol: .rsrc
		binary.Write(&b, binary.LittleEndian, relocType)
	}
	// Symbol 0: ".rsrc", section 1, static, one aux record.
	var sym [18]byte
	copy(sym[:8], ".rsrc")
	binary.LittleEndian.PutUint16(sym[12:], 1) // SectionNumber
	sym[16] = 3                                // IMAGE_SYM_CLASS_STATIC
	sym[17] = 1                                // NumberOfAuxSymbols
	b.Write(sym[:])
	var aux [18]byte
	binary.LittleEndian.PutUint32(aux[0:], uint32(len(sec)))
	binary.LittleEndian.PutUint16(aux[4:], uint16(len(res)))
	b.Write(aux[:])
	binary.Write(&b, binary.LittleEndian, uint32(4)) // string table: its size only
	return b.Bytes()
}

// manifest: per-monitor-v2 DPI awareness (crisp at any scaling), common
// controls v6 (Windows 11 dialogs), long paths, run as the user.
const manifest = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
  <assemblyIdentity type="win32" name="io.bromure.sidecar" version="1.0.0.0"/>
  <description>Bromure Sidecar</description>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application><supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/></application>
  </compatibility>
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </asmv3:windowsSettings>
  </asmv3:application>
</assembly>
`
