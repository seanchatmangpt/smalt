package diffpprof

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Wire types in Protocol Buffers.
const (
	wireVarint  = 0
	wireFixed64 = 1
	wireBytes   = 2
	wireFixed32 = 5
)

// Profile represents a pprof profile stream.
type Profile struct {
	SampleType        []*ValueType
	Sample            []*Sample
	Mapping           []*Mapping
	Location          []*Location
	Function          []*Function
	StringTable       []string
	DropFrames        int64
	KeepFrames        int64
	TimeNanos         int64
	DurationNanos     int64
	PeriodType        *ValueType
	Period            int64
	Comment           []int64
	DefaultSampleType int64

	// Internal lookup indexes
	functionMap map[uint64]*Function
	locationMap map[uint64]*Location
}

// ValueType specifies a metric type and unit.
type ValueType struct {
	Type string
	Unit string
}

// Sample represents a single execution or allocation sample point.
type Sample struct {
	LocationIDs []uint64
	Locations   []*Location
	Values      []int64
	Labels      map[string][]string
	NumLabels   map[string][]int64
	NumUnit     []string
}

// Location represents a code location in a binary.
type Location struct {
	ID        uint64
	MappingID uint64
	Address   uint64
	Lines     []Line
	IsFolded  bool
}

// Line represents a source line associated with a Function.
type Line struct {
	Function   *Function
	FunctionID uint64
	LineNumber int64
}

// Function represents a function symbol.
type Function struct {
	ID         uint64
	Name       string
	SystemName string
	Filename   string
	StartLine  int64
}

// Mapping represents a memory mapping.
type Mapping struct {
	ID              uint64
	MemoryStart     uint64
	MemoryLimit     uint64
	FileOffset      uint64
	Filename        string
	BuildID         string
	HasFunctions    bool
	HasFilenames    bool
	HasLineNumbers  bool
	HasInlineFrames bool
}

// ParseProfile parses a pprof profile from an io.Reader.
// Automatically handles gzip-compressed or raw protobuf streams.
func ParseProfile(r io.Reader) (*Profile, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read profile stream: %w", err)
	}
	if len(data) == 0 {
		return nil, errors.New("empty profile stream")
	}

	// Detect gzip compression magic bytes (0x1f, 0x8b)
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		gz, err := gzip.NewReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("gzip reader init: %w", err)
		}
		defer gz.Close()
		decompressed, err := io.ReadAll(gz)
		if err != nil {
			return nil, fmt.Errorf("gzip decompression: %w", err)
		}
		data = decompressed
	}

	p := &Profile{
		functionMap: make(map[uint64]*Function),
		locationMap: make(map[uint64]*Location),
	}

	if err := decodeProfileProto(data, p); err != nil {
		return nil, fmt.Errorf("decode profile protobuf: %w", err)
	}

	p.linkReferences()
	return p, nil
}

// linkReferences resolves IDs to their respective objects.
func (p *Profile) linkReferences() {
	if p.functionMap == nil {
		p.functionMap = make(map[uint64]*Function)
	}
	if p.locationMap == nil {
		p.locationMap = make(map[uint64]*Location)
	}
	for _, fn := range p.Function {
		p.functionMap[fn.ID] = fn
	}
	for _, loc := range p.Location {
		for i := range loc.Lines {
			if fn, ok := p.functionMap[loc.Lines[i].FunctionID]; ok {
				loc.Lines[i].Function = fn
			}
		}
		p.locationMap[loc.ID] = loc
	}
	for _, s := range p.Sample {
		s.Locations = make([]*Location, 0, len(s.LocationIDs))
		for _, lid := range s.LocationIDs {
			if loc, ok := p.locationMap[lid]; ok {
				s.Locations = append(s.Locations, loc)
			}
		}
	}
}

func (p *Profile) getString(idx int64) string {
	if idx >= 0 && int(idx) < len(p.StringTable) {
		return p.StringTable[idx]
	}
	return ""
}

// Raw unlinked proto structures
type rawValueType struct {
	typ  int64
	unit int64
}

type rawLine struct {
	functionID uint64
	line       int64
}

type rawLocation struct {
	id        uint64
	mappingID uint64
	address   uint64
	lines     []rawLine
	isFolded  bool
}

type rawFunction struct {
	id         uint64
	name       int64
	systemName int64
	filename   int64
	startLine  int64
}

type rawMapping struct {
	id              uint64
	memoryStart     uint64
	memoryLimit     uint64
	fileOffset      uint64
	filename        int64
	buildID         int64
	hasFunctions    bool
	hasFilenames    bool
	hasLineNumbers  bool
	hasInlineFrames bool
}

type rawLabel struct {
	key     int64
	str     int64
	num     int64
	numUnit int64
}

type rawSample struct {
	locationIDs []uint64
	values      []int64
	labels      []rawLabel
}

func decodeProfileProto(data []byte, p *Profile) error {
	var rawSampleTypes []rawValueType
	var rawSamples []rawSample
	var rawMappings []rawMapping
	var rawLocations []rawLocation
	var rawFunctions []rawFunction
	var rawPeriodType rawValueType

	pos := 0
	for pos < len(data) {
		key, n, err := decodeVarint(data[pos:])
		if err != nil {
			return err
		}
		pos += n

		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)

		switch fieldNum {
		case 1: // sample_type (repeated ValueType)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			vt, err := decodeRawValueType(b)
			if err != nil {
				return err
			}
			rawSampleTypes = append(rawSampleTypes, vt)
		case 2: // sample (repeated Sample)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			s, err := decodeRawSample(b)
			if err != nil {
				return err
			}
			rawSamples = append(rawSamples, s)
		case 3: // mapping (repeated Mapping)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			m, err := decodeRawMapping(b)
			if err != nil {
				return err
			}
			rawMappings = append(rawMappings, m)
		case 4: // location (repeated Location)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			loc, err := decodeRawLocation(b)
			if err != nil {
				return err
			}
			rawLocations = append(rawLocations, loc)
		case 5: // function (repeated Function)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			fn, err := decodeRawFunction(b)
			if err != nil {
				return err
			}
			rawFunctions = append(rawFunctions, fn)
		case 6: // string_table (repeated string)
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			p.StringTable = append(p.StringTable, string(b))
		case 7: // drop_frames
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.DropFrames = int64(v)
		case 8: // keep_frames
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.KeepFrames = int64(v)
		case 9: // time_nanos
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.TimeNanos = int64(v)
		case 10: // duration_nanos
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.DurationNanos = int64(v)
		case 11: // period_type
			b, n, err := decodeBytes(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
			rawPeriodType, _ = decodeRawValueType(b)
		case 12: // period
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.Period = int64(v)
		case 13: // comment
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.Comment = append(p.Comment, int64(v))
		case 14: // default_sample_type
			v, n, err := decodeVarint(data[pos:])
			if err != nil {
				return err
			}
			pos += n
			p.DefaultSampleType = int64(v)
		default:
			n, err := skipField(data[pos:], wireType)
			if err != nil {
				return err
			}
			pos += n
		}
	}

	// Resolve string references
	for _, rvt := range rawSampleTypes {
		p.SampleType = append(p.SampleType, &ValueType{
			Type: p.getString(rvt.typ),
			Unit: p.getString(rvt.unit),
		})
	}
	if rawPeriodType.typ != 0 || rawPeriodType.unit != 0 {
		p.PeriodType = &ValueType{
			Type: p.getString(rawPeriodType.typ),
			Unit: p.getString(rawPeriodType.unit),
		}
	}

	for _, rf := range rawFunctions {
		p.Function = append(p.Function, &Function{
			ID:         rf.id,
			Name:       p.getString(rf.name),
			SystemName: p.getString(rf.systemName),
			Filename:   p.getString(rf.filename),
			StartLine:  rf.startLine,
		})
	}

	for _, rm := range rawMappings {
		p.Mapping = append(p.Mapping, &Mapping{
			ID:              rm.id,
			MemoryStart:     rm.memoryStart,
			MemoryLimit:     rm.memoryLimit,
			FileOffset:      rm.fileOffset,
			Filename:        p.getString(rm.filename),
			BuildID:         p.getString(rm.buildID),
			HasFunctions:    rm.hasFunctions,
			HasFilenames:    rm.hasFilenames,
			HasLineNumbers:  rm.hasLineNumbers,
			HasInlineFrames: rm.hasInlineFrames,
		})
	}

	for _, rl := range rawLocations {
		lines := make([]Line, 0, len(rl.lines))
		for _, ln := range rl.lines {
			lines = append(lines, Line{
				FunctionID: ln.functionID,
				LineNumber: ln.line,
			})
		}
		p.Location = append(p.Location, &Location{
			ID:        rl.id,
			MappingID: rl.mappingID,
			Address:   rl.address,
			Lines:     lines,
			IsFolded:  rl.isFolded,
		})
	}

	for _, rs := range rawSamples {
		s := &Sample{
			LocationIDs: rs.locationIDs,
			Values:      rs.values,
			Labels:      make(map[string][]string),
			NumLabels:   make(map[string][]int64),
		}
		for _, lbl := range rs.labels {
			key := p.getString(lbl.key)
			if lbl.str != 0 {
				s.Labels[key] = append(s.Labels[key], p.getString(lbl.str))
			}
			if lbl.num != 0 {
				s.NumLabels[key] = append(s.NumLabels[key], lbl.num)
			}
		}
		p.Sample = append(p.Sample, s)
	}

	return nil
}

func decodeRawValueType(b []byte) (rawValueType, error) {
	var vt rawValueType
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return vt, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)
		if wireType == wireVarint {
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return vt, err
			}
			pos += n
			if fieldNum == 1 {
				vt.typ = int64(v)
			} else if fieldNum == 2 {
				vt.unit = int64(v)
			}
		} else {
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return vt, err
			}
			pos += n
		}
	}
	return vt, nil
}

func decodeRawSample(b []byte) (rawSample, error) {
	var s rawSample
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return s, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)

		switch fieldNum {
		case 1: // location_id (packed or unpacked)
			if wireType == wireBytes {
				sub, n, err := decodeBytes(b[pos:], wireType)
				if err != nil {
					return s, err
				}
				pos += n
				spos := 0
				for spos < len(sub) {
					v, sn, err := decodeVarint(sub[spos:])
					if err != nil {
						return s, err
					}
					spos += sn
					s.locationIDs = append(s.locationIDs, v)
				}
			} else if wireType == wireVarint {
				v, n, err := decodeVarint(b[pos:])
				if err != nil {
					return s, err
				}
				pos += n
				s.locationIDs = append(s.locationIDs, v)
			}
		case 2: // value (packed or unpacked)
			if wireType == wireBytes {
				sub, n, err := decodeBytes(b[pos:], wireType)
				if err != nil {
					return s, err
				}
				pos += n
				spos := 0
				for spos < len(sub) {
					v, sn, err := decodeVarint(sub[spos:])
					if err != nil {
						return s, err
					}
					spos += sn
					s.values = append(s.values, int64(v))
				}
			} else if wireType == wireVarint {
				v, n, err := decodeVarint(b[pos:])
				if err != nil {
					return s, err
				}
				pos += n
				s.values = append(s.values, int64(v))
			}
		case 3: // label
			sub, n, err := decodeBytes(b[pos:], wireType)
			if err != nil {
				return s, err
			}
			pos += n
			lbl, err := decodeRawLabel(sub)
			if err != nil {
				return s, err
			}
			s.labels = append(s.labels, lbl)
		default:
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return s, err
			}
			pos += n
		}
	}
	return s, nil
}

func decodeRawLabel(b []byte) (rawLabel, error) {
	var lbl rawLabel
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return lbl, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)
		if wireType == wireVarint {
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return lbl, err
			}
			pos += n
			switch fieldNum {
			case 1:
				lbl.key = int64(v)
			case 2:
				lbl.str = int64(v)
			case 3:
				lbl.num = int64(v)
			case 4:
				lbl.numUnit = int64(v)
			}
		} else {
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return lbl, err
			}
			pos += n
		}
	}
	return lbl, nil
}

func decodeRawLocation(b []byte) (rawLocation, error) {
	var loc rawLocation
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return loc, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)

		switch fieldNum {
		case 1:
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return loc, err
			}
			pos += n
			loc.id = v
		case 2:
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return loc, err
			}
			pos += n
			loc.mappingID = v
		case 3:
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return loc, err
			}
			pos += n
			loc.address = v
		case 4: // line (repeated Line)
			sub, n, err := decodeBytes(b[pos:], wireType)
			if err != nil {
				return loc, err
			}
			pos += n
			ln, err := decodeRawLine(sub)
			if err != nil {
				return loc, err
			}
			loc.lines = append(loc.lines, ln)
		case 5:
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return loc, err
			}
			pos += n
			loc.isFolded = (v != 0)
		default:
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return loc, err
			}
			pos += n
		}
	}
	return loc, nil
}

func decodeRawLine(b []byte) (rawLine, error) {
	var ln rawLine
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return ln, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)
		if wireType == wireVarint {
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return ln, err
			}
			pos += n
			if fieldNum == 1 {
				ln.functionID = v
			} else if fieldNum == 2 {
				ln.line = int64(v)
			}
		} else {
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return ln, err
			}
			pos += n
		}
	}
	return ln, nil
}

func decodeRawFunction(b []byte) (rawFunction, error) {
	var fn rawFunction
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return fn, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)

		if wireType == wireVarint {
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return fn, err
			}
			pos += n
			switch fieldNum {
			case 1:
				fn.id = v
			case 2:
				fn.name = int64(v)
			case 3:
				fn.systemName = int64(v)
			case 4:
				fn.filename = int64(v)
			case 5:
				fn.startLine = int64(v)
			}
		} else {
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return fn, err
			}
			pos += n
		}
	}
	return fn, nil
}

func decodeRawMapping(b []byte) (rawMapping, error) {
	var rm rawMapping
	pos := 0
	for pos < len(b) {
		key, n, err := decodeVarint(b[pos:])
		if err != nil {
			return rm, err
		}
		pos += n
		fieldNum := int(key >> 3)
		wireType := int(key & 0x7)

		if wireType == wireVarint {
			v, n, err := decodeVarint(b[pos:])
			if err != nil {
				return rm, err
			}
			pos += n
			switch fieldNum {
			case 1:
				rm.id = v
			case 2:
				rm.memoryStart = v
			case 3:
				rm.memoryLimit = v
			case 4:
				rm.fileOffset = v
			case 5:
				rm.filename = int64(v)
			case 6:
				rm.buildID = int64(v)
			case 7:
				rm.hasFunctions = (v != 0)
			case 8:
				rm.hasFilenames = (v != 0)
			case 9:
				rm.hasLineNumbers = (v != 0)
			case 10:
				rm.hasInlineFrames = (v != 0)
			}
		} else {
			n, err := skipField(b[pos:], wireType)
			if err != nil {
				return rm, err
			}
			pos += n
		}
	}
	return rm, nil
}

// Low-level protobuf helpers
func decodeVarint(data []byte) (uint64, int, error) {
	var x uint64
	var s uint
	for i, b := range data {
		if i >= 10 {
			return 0, 0, errors.New("protobuf: varint overflow")
		}
		if b < 0x80 {
			if i == 9 && b > 1 {
				return 0, 0, errors.New("protobuf: varint overflow")
			}
			return x | uint64(b)<<s, i + 1, nil
		}
		x |= uint64(b&0x7f) << s
		s += 7
	}
	return 0, 0, io.ErrUnexpectedEOF
}

func decodeBytes(data []byte, wireType int) ([]byte, int, error) {
	if wireType != wireBytes {
		return nil, 0, fmt.Errorf("expected wireType 2, got %d", wireType)
	}
	length, n, err := decodeVarint(data)
	if err != nil {
		return nil, 0, err
	}
	total := n + int(length)
	if total > len(data) {
		return nil, 0, io.ErrUnexpectedEOF
	}
	return data[n:total], total, nil
}

func skipField(data []byte, wireType int) (int, error) {
	switch wireType {
	case wireVarint:
		_, n, err := decodeVarint(data)
		return n, err
	case wireFixed64:
		if len(data) < 8 {
			return 0, io.ErrUnexpectedEOF
		}
		return 8, nil
	case wireBytes:
		length, n, err := decodeVarint(data)
		if err != nil {
			return 0, err
		}
		total := n + int(length)
		if total > len(data) {
			return 0, io.ErrUnexpectedEOF
		}
		return total, nil
	case wireFixed32:
		if len(data) < 4 {
			return 0, io.ErrUnexpectedEOF
		}
		return 4, nil
	default:
		return 0, fmt.Errorf("unsupported wire type: %d", wireType)
	}
}

// Encode writes the Profile as gzip-compressed pprof protobuf.
func (p *Profile) Encode(w io.Writer) error {
	raw := p.encodeProto()
	gw := gzip.NewWriter(w)
	if _, err := gw.Write(raw); err != nil {
		return err
	}
	return gw.Close()
}

func (p *Profile) encodeProto() []byte {
	strMap := make(map[string]int64)
	var strTable []string
	intern := func(s string) int64 {
		if idx, ok := strMap[s]; ok {
			return idx
		}
		idx := int64(len(strTable))
		strTable = append(strTable, s)
		strMap[s] = idx
		return idx
	}

	// Index 0 in string_table is always ""
	intern("")

	var buf []byte

	// 1. sample_type
	for _, st := range p.SampleType {
		typeIdx := intern(st.Type)
		unitIdx := intern(st.Unit)
		var vtBuf []byte
		vtBuf = appendVarintField(vtBuf, 1, uint64(typeIdx))
		vtBuf = appendVarintField(vtBuf, 2, uint64(unitIdx))
		buf = appendBytesField(buf, 1, vtBuf)
	}

	// 2. sample
	for _, s := range p.Sample {
		var sBuf []byte
		for _, lid := range s.LocationIDs {
			sBuf = appendVarintField(sBuf, 1, lid)
		}
		for _, val := range s.Values {
			sBuf = appendVarintField(sBuf, 2, uint64(val))
		}
		for k, vals := range s.Labels {
			kIdx := intern(k)
			for _, v := range vals {
				vIdx := intern(v)
				var lBuf []byte
				lBuf = appendVarintField(lBuf, 1, uint64(kIdx))
				lBuf = appendVarintField(lBuf, 2, uint64(vIdx))
				sBuf = appendBytesField(sBuf, 3, lBuf)
			}
		}
		buf = appendBytesField(buf, 2, sBuf)
	}

	// 4. location
	for _, loc := range p.Location {
		var locBuf []byte
		locBuf = appendVarintField(locBuf, 1, loc.ID)
		locBuf = appendVarintField(locBuf, 2, loc.MappingID)
		locBuf = appendVarintField(locBuf, 3, loc.Address)
		for _, ln := range loc.Lines {
			var lnBuf []byte
			lnBuf = appendVarintField(lnBuf, 1, ln.FunctionID)
			lnBuf = appendVarintField(lnBuf, 2, uint64(ln.LineNumber))
			locBuf = appendBytesField(locBuf, 4, lnBuf)
		}
		buf = appendBytesField(buf, 4, locBuf)
	}

	// 5. function
	for _, fn := range p.Function {
		var fnBuf []byte
		fnBuf = appendVarintField(fnBuf, 1, fn.ID)
		fnBuf = appendVarintField(fnBuf, 2, uint64(intern(fn.Name)))
		fnBuf = appendVarintField(fnBuf, 3, uint64(intern(fn.SystemName)))
		fnBuf = appendVarintField(fnBuf, 4, uint64(intern(fn.Filename)))
		fnBuf = appendVarintField(fnBuf, 5, uint64(fn.StartLine))
		buf = appendBytesField(buf, 5, fnBuf)
	}

	// 6. string_table
	for _, s := range strTable {
		buf = appendStringField(buf, 6, s)
	}

	// 9. time_nanos
	if p.TimeNanos != 0 {
		buf = appendVarintField(buf, 9, uint64(p.TimeNanos))
	}
	// 10. duration_nanos
	if p.DurationNanos != 0 {
		buf = appendVarintField(buf, 10, uint64(p.DurationNanos))
	}

	return buf
}

func appendVarint(dst []byte, x uint64) []byte {
	for x >= 0x80 {
		dst = append(dst, byte(x)|0x80)
		x >>= 7
	}
	return append(dst, byte(x))
}

func appendTag(dst []byte, fieldNum int, wireType int) []byte {
	return appendVarint(dst, uint64(fieldNum<<3|wireType))
}

func appendBytesField(dst []byte, fieldNum int, b []byte) []byte {
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(len(b)))
	return append(dst, b...)
}

func appendStringField(dst []byte, fieldNum int, s string) []byte {
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(len(s)))
	return append(dst, s...)
}

func appendVarintField(dst []byte, fieldNum int, v uint64) []byte {
	dst = appendTag(dst, fieldNum, wireVarint)
	return appendVarint(dst, v)
}

// SymbolMetrics holds extracted metrics for an individual function symbol.
type SymbolMetrics struct {
	Symbol          string
	Filename        string
	StartLine       int64
	FlatAllocBytes  int64
	FlatAllocCount  int64
	FlatInuseBytes  int64
	FlatInuseCount  int64
	FlatCPUSamples  int64
	FlatCPUNanos    int64
	CumAllocBytes   int64
	CumAllocCount   int64
	CumCPUSamples   int64
	CumCPUNanos     int64
}

// ExtractSymbolMetrics analyzes the profile and aggregates metrics per function symbol.
func (p *Profile) ExtractSymbolMetrics() map[string]*SymbolMetrics {
	res := make(map[string]*SymbolMetrics)

	// Determine sample type indices
	allocBytesIdx := -1
	allocCountIdx := -1
	inuseBytesIdx := -1
	inuseCountIdx := -1
	cpuSamplesIdx := -1
	cpuNanosIdx := -1

	for idx, st := range p.SampleType {
		switch st.Type {
		case "alloc_space":
			allocBytesIdx = idx
		case "alloc_objects":
			allocCountIdx = idx
		case "inuse_space":
			inuseBytesIdx = idx
		case "inuse_objects":
			inuseCountIdx = idx
		case "samples":
			cpuSamplesIdx = idx
		case "cpu":
			cpuNanosIdx = idx
		}
	}

	getVal := func(vals []int64, idx int) int64 {
		if idx >= 0 && idx < len(vals) {
			return vals[idx]
		}
		return 0
	}

	getOrCreate := func(fn *Function) *SymbolMetrics {
		name := fn.Name
		if name == "" {
			name = fn.SystemName
		}
		if name == "" {
			name = fmt.Sprintf("fn_0x%x", fn.ID)
		}
		sm, ok := res[name]
		if !ok {
			sm = &SymbolMetrics{
				Symbol:    name,
				Filename:  fn.Filename,
				StartLine: fn.StartLine,
			}
			res[name] = sm
		}
		return sm
	}

	for _, s := range p.Sample {
		if len(s.Locations) == 0 {
			continue
		}

		allocBytes := getVal(s.Values, allocBytesIdx)
		allocCount := getVal(s.Values, allocCountIdx)
		inuseBytes := getVal(s.Values, inuseBytesIdx)
		inuseCount := getVal(s.Values, inuseCountIdx)
		cpuSamples := getVal(s.Values, cpuSamplesIdx)
		cpuNanos := getVal(s.Values, cpuNanosIdx)

		// Flat attribution on leaf function (first location, first line)
		leafLoc := s.Locations[0]
		if len(leafLoc.Lines) > 0 && leafLoc.Lines[0].Function != nil {
			sm := getOrCreate(leafLoc.Lines[0].Function)
			sm.FlatAllocBytes += allocBytes
			sm.FlatAllocCount += allocCount
			sm.FlatInuseBytes += inuseBytes
			sm.FlatInuseCount += inuseCount
			sm.FlatCPUSamples += cpuSamples
			sm.FlatCPUNanos += cpuNanos
		}

		// Cumulative attribution across call stack (dedup per sample)
		seen := make(map[uint64]bool)
		for _, loc := range s.Locations {
			for _, line := range loc.Lines {
				if line.Function != nil && !seen[line.Function.ID] {
					seen[line.Function.ID] = true
					sm := getOrCreate(line.Function)
					sm.CumAllocBytes += allocBytes
					sm.CumAllocCount += allocCount
					sm.CumCPUSamples += cpuSamples
					sm.CumCPUNanos += cpuNanos
				}
			}
		}
	}

	return res
}

// SymbolDelta holds comparative metrics for a function symbol between baseline and candidate.
type SymbolDelta struct {
	Symbol            string   `json:"symbol"`
	Filename          string   `json:"filename,omitempty"`
	StartLine         int64    `json:"start_line,omitempty"`
	BaselineAllocB    int64    `json:"baseline_alloc_bytes"`
	CandidateAllocB   int64    `json:"candidate_alloc_bytes"`
	DeltaAllocB       int64    `json:"delta_alloc_bytes"`
	BaselineAllocs    int64    `json:"baseline_alloc_objects"`
	CandidateAllocs   int64    `json:"candidate_alloc_objects"`
	DeltaAllocs       int64    `json:"delta_alloc_objects"`
	BaselineCPU       int64    `json:"baseline_cpu_samples"`
	CandidateCPU      int64    `json:"candidate_cpu_samples"`
	DeltaCPU          int64    `json:"delta_cpu_samples"`
	DeltaCPUPct       float64  `json:"delta_cpu_percent"`
	IsRegression      bool     `json:"is_regression"`
	ExceedsZeroAlloc  bool     `json:"exceeds_zero_alloc"`
	Status            string   `json:"status"` // "PASS", "REGRESSION", "ZERO_ALLOC_VIOLATION", "IMPROVEMENT"
	RegressionReasons []string `json:"regression_reasons,omitempty"`
}

// ProfileDiff encapsulates the delta analysis between baseline and candidate profiles.
type ProfileDiff struct {
	BaselineTotalAllocB   int64          `json:"baseline_total_alloc_bytes"`
	CandidateTotalAllocB  int64          `json:"candidate_total_alloc_bytes"`
	DeltaTotalAllocB      int64          `json:"delta_total_alloc_bytes"`
	BaselineTotalAllocs   int64          `json:"baseline_total_allocs"`
	CandidateTotalAllocs  int64          `json:"candidate_total_allocs"`
	DeltaTotalAllocs      int64          `json:"delta_total_allocs"`
	BaselineTotalCPU      int64          `json:"baseline_total_cpu_samples"`
	CandidateTotalCPU     int64          `json:"candidate_total_cpu_samples"`
	DeltaTotalCPU         int64          `json:"delta_total_cpu_samples"`
	ZeroAllocPassed       bool           `json:"zero_alloc_passed"`
	Symbols               []*SymbolDelta `json:"symbols"`
	Regressions           []*SymbolDelta `json:"regressions"`
}

// HasRegression reports whether any symbol has a marked regression.
func (d *ProfileDiff) HasRegression() bool {
	return len(d.Regressions) > 0
}

// ExceedsZeroAlloc reports whether candidate allocated anything exceeding zero-alloc bounds.
func (d *ProfileDiff) ExceedsZeroAlloc() bool {
	return !d.ZeroAllocPassed
}

// DiffOptions configures comparison behavior and regression thresholds.
type DiffOptions struct {
	MaxDeltaAllocBytes   int64                      // Max tolerable delta bytes (default: 0)
	MaxDeltaAllocObjects int64                      // Max tolerable delta alloc objects (default: 0)
	MaxDeltaCPUPct       float64                    // Max tolerable delta CPU percent (default: 5.0)
	StrictZeroAlloc      bool                       // Enforce zero allocations for candidate
	TopN                 int                        // Max symbols to display in table (0 for all)
	SortBy               string                     // "bytes", "allocs", "cpu", "name" (default: "bytes")
	Filter               func(symbol string) bool   // Optional symbol name filter
}

// DefaultDiffOptions provides strict zero-alloc baseline thresholds.
func DefaultDiffOptions() DiffOptions {
	return DiffOptions{
		MaxDeltaAllocBytes:   0,
		MaxDeltaAllocObjects: 0,
		MaxDeltaCPUPct:       5.0,
		StrictZeroAlloc:      true,
		TopN:                 25,
		SortBy:               "bytes",
	}
}

// Option configures DiffOptions.
type Option func(*DiffOptions)

// WithStrictZeroAlloc configures strict zero-allocation checking.
func WithStrictZeroAlloc(strict bool) Option {
	return func(o *DiffOptions) {
		o.StrictZeroAlloc = strict
	}
}

// WithTopN limits the output to top N symbols.
func WithTopN(n int) Option {
	return func(o *DiffOptions) {
		o.TopN = n
	}
}

// WithSortBy sets the sort criterion ("bytes", "allocs", "cpu", "name").
func WithSortBy(sortBy string) Option {
	return func(o *DiffOptions) {
		o.SortBy = sortBy
	}
}

// WithTolerance sets custom delta bounds before marking a regression.
func WithTolerance(maxDeltaBytes int64, maxDeltaAllocs int64, maxCPUPct float64) Option {
	return func(o *DiffOptions) {
		o.MaxDeltaAllocBytes = maxDeltaBytes
		o.MaxDeltaAllocObjects = maxDeltaAllocs
		o.MaxDeltaCPUPct = maxCPUPct
	}
}

// Compare compares two pprof profile streams (baseline vs candidate).
func Compare(baseline, candidate io.Reader, opts ...Option) (*ProfileDiff, error) {
	baseP, err := ParseProfile(baseline)
	if err != nil {
		return nil, fmt.Errorf("parse baseline profile: %w", err)
	}
	candP, err := ParseProfile(candidate)
	if err != nil {
		return nil, fmt.Errorf("parse candidate profile: %w", err)
	}
	return CompareProfiles(baseP, candP, opts...), nil
}

// CompareProfiles compares two parsed Profiles.
func CompareProfiles(baseline, candidate *Profile, opts ...Option) *ProfileDiff {
	cfg := DefaultDiffOptions()
	for _, opt := range opts {
		opt(&cfg)
	}

	baseMetrics := baseline.ExtractSymbolMetrics()
	candMetrics := candidate.ExtractSymbolMetrics()

	allSymbols := make(map[string]bool)
	for s := range baseMetrics {
		if cfg.Filter == nil || cfg.Filter(s) {
			allSymbols[s] = true
		}
	}
	for s := range candMetrics {
		if cfg.Filter == nil || cfg.Filter(s) {
			allSymbols[s] = true
		}
	}

	diff := &ProfileDiff{
		ZeroAllocPassed: true,
	}

	for sym := range allSymbols {
		var baseAllocB, baseAllocs, baseCPU int64
		var candAllocB, candAllocs, candCPU int64
		var fn string
		var line int64

		if bm, ok := baseMetrics[sym]; ok {
			baseAllocB = bm.FlatAllocBytes
			baseAllocs = bm.FlatAllocCount
			baseCPU = bm.FlatCPUSamples
			fn = bm.Filename
			line = bm.StartLine
		}
		if cm, ok := candMetrics[sym]; ok {
			candAllocB = cm.FlatAllocBytes
			candAllocs = cm.FlatAllocCount
			candCPU = cm.FlatCPUSamples
			if fn == "" {
				fn = cm.Filename
				line = cm.StartLine
			}
		}

		deltaAllocB := candAllocB - baseAllocB
		deltaAllocs := candAllocs - baseAllocs
		deltaCPU := candCPU - baseCPU

		diff.BaselineTotalAllocB += baseAllocB
		diff.CandidateTotalAllocB += candAllocB
		diff.BaselineTotalAllocs += baseAllocs
		diff.CandidateTotalAllocs += candAllocs
		diff.BaselineTotalCPU += baseCPU
		diff.CandidateTotalCPU += candCPU

		var cpuPct float64
		if baseCPU > 0 {
			cpuPct = (float64(deltaCPU) / float64(baseCPU)) * 100.0
		} else if candCPU > 0 {
			cpuPct = 100.0
		}

		isRegression := false
		exceedsZeroAlloc := false
		var reasons []string

		// Check zero-allocation invariant:
		// If strict zero-alloc is on and candidate allocated bytes/objects
		if cfg.StrictZeroAlloc && (candAllocB > 0 || candAllocs > 0) {
			exceedsZeroAlloc = true
			isRegression = true
			reasons = append(reasons, fmt.Sprintf("violates zero-alloc bound: candidate allocated %d B (%d objects)", candAllocB, candAllocs))
			diff.ZeroAllocPassed = false
		} else if deltaAllocB > cfg.MaxDeltaAllocBytes {
			isRegression = true
			reasons = append(reasons, fmt.Sprintf("alloc bytes regressed +%d B (threshold: %d B)", deltaAllocB, cfg.MaxDeltaAllocBytes))
		} else if deltaAllocs > cfg.MaxDeltaAllocObjects {
			isRegression = true
			reasons = append(reasons, fmt.Sprintf("alloc count regressed +%d allocs (threshold: %d)", deltaAllocs, cfg.MaxDeltaAllocObjects))
		}

		if cfg.MaxDeltaCPUPct > 0 && cpuPct > cfg.MaxDeltaCPUPct && deltaCPU > 0 {
			isRegression = true
			reasons = append(reasons, fmt.Sprintf("CPU regressed +%.1f%% (threshold: +%.1f%%)", cpuPct, cfg.MaxDeltaCPUPct))
		}

		status := "PASS"
		if exceedsZeroAlloc {
			status = "ZERO_ALLOC_VIOLATION"
		} else if isRegression {
			status = "REGRESSION"
		} else if deltaAllocB < 0 || deltaAllocs < 0 || deltaCPU < 0 {
			status = "IMPROVEMENT"
		}

		sd := &SymbolDelta{
			Symbol:            sym,
			Filename:          fn,
			StartLine:         line,
			BaselineAllocB:    baseAllocB,
			CandidateAllocB:   candAllocB,
			DeltaAllocB:       deltaAllocB,
			BaselineAllocs:    baseAllocs,
			CandidateAllocs:   candAllocs,
			DeltaAllocs:       deltaAllocs,
			BaselineCPU:       baseCPU,
			CandidateCPU:      candCPU,
			DeltaCPU:          deltaCPU,
			DeltaCPUPct:       cpuPct,
			IsRegression:      isRegression,
			ExceedsZeroAlloc:  exceedsZeroAlloc,
			Status:            status,
			RegressionReasons: reasons,
		}

		diff.Symbols = append(diff.Symbols, sd)
		if isRegression {
			diff.Regressions = append(diff.Regressions, sd)
		}
	}

	diff.DeltaTotalAllocB = diff.CandidateTotalAllocB - diff.BaselineTotalAllocB
	diff.DeltaTotalAllocs = diff.CandidateTotalAllocs - diff.BaselineTotalAllocs
	diff.DeltaTotalCPU = diff.CandidateTotalCPU - diff.BaselineTotalCPU

	// Sort symbols
	sort.Slice(diff.Symbols, func(i, j int) bool {
		switch cfg.SortBy {
		case "allocs":
			if diff.Symbols[i].DeltaAllocs != diff.Symbols[j].DeltaAllocs {
				return diff.Symbols[i].DeltaAllocs > diff.Symbols[j].DeltaAllocs
			}
		case "cpu":
			if diff.Symbols[i].DeltaCPU != diff.Symbols[j].DeltaCPU {
				return diff.Symbols[i].DeltaCPU > diff.Symbols[j].DeltaCPU
			}
		case "name":
			return diff.Symbols[i].Symbol < diff.Symbols[j].Symbol
		default: // "bytes"
			if diff.Symbols[i].DeltaAllocB != diff.Symbols[j].DeltaAllocB {
				return diff.Symbols[i].DeltaAllocB > diff.Symbols[j].DeltaAllocB
			}
		}
		return diff.Symbols[i].Symbol < diff.Symbols[j].Symbol
	})

	if cfg.TopN > 0 && len(diff.Symbols) > cfg.TopN {
		diff.Symbols = diff.Symbols[:cfg.TopN]
	}

	return diff
}

// FormatTable formats a terminal-friendly diff table highlighting any regression.
func (d *ProfileDiff) FormatTable(color bool) string {
	var b strings.Builder

	red := ""
	green := ""
	yellow := ""
	cyan := ""
	bold := ""
	reset := ""

	if color {
		red = "\033[31;1m"
		green = "\033[32;1m"
		yellow = "\033[33;1m"
		cyan = "\033[36;1m"
		bold = "\033[1m"
		reset = "\033[0m"
	}

	b.WriteString(bold + cyan + "======================================================================================================\n" + reset)
	b.WriteString(bold + "                     POSH DIFFERENTIAL PPROF ENGINE (v26.10.30)                      \n" + reset)
	b.WriteString(bold + cyan + "======================================================================================================\n" + reset)

	// Column header
	b.WriteString(fmt.Sprintf("%-38s | %10s | %10s | %10s | %8s | %s\n",
		"FUNCTION / SYMBOL", "DELTA BYTES", "DELTA ALLOCS", "DELTA CPU", "STATUS", "DETAILS"))
	b.WriteString("---------------------------------------+------------+------------+------------+----------+------------\n")

	for _, sd := range d.Symbols {
		sym := sd.Symbol
		if len(sym) > 38 {
			sym = sym[:35] + "..."
		}

		deltaBytesStr := fmt.Sprintf("%+d B", sd.DeltaAllocB)
		deltaAllocsStr := fmt.Sprintf("%+d", sd.DeltaAllocs)
		deltaCPUStr := fmt.Sprintf("%+d", sd.DeltaCPU)

		statusColor := green
		statusTag := "[OK]"
		if sd.ExceedsZeroAlloc {
			statusColor = red
			statusTag = "[FAIL]"
		} else if sd.IsRegression {
			statusColor = yellow
			statusTag = "[WARN]"
		} else if sd.DeltaAllocB < 0 || sd.DeltaAllocs < 0 {
			statusColor = green
			statusTag = "[IMP]"
		}

		details := ""
		if len(sd.RegressionReasons) > 0 {
			details = sd.RegressionReasons[0]
		} else if sd.CandidateAllocB == 0 && sd.CandidateAllocs == 0 {
			details = "zero-alloc verified"
		}

		b.WriteString(fmt.Sprintf("%-38s | %10s | %10s | %10s | %s%-8s%s | %s\n",
			sym, deltaBytesStr, deltaAllocsStr, deltaCPUStr, statusColor, statusTag, reset, details))
	}

	b.WriteString("---------------------------------------+------------+------------+------------+----------+------------\n")
	b.WriteString(bold + "TOTALS:\n" + reset)
	b.WriteString(fmt.Sprintf("  Alloc Space:   Baseline: %8d B  ->  Candidate: %8d B  (Delta: %+d B)\n",
		d.BaselineTotalAllocB, d.CandidateTotalAllocB, d.DeltaTotalAllocB))
	b.WriteString(fmt.Sprintf("  Alloc Objects: Baseline: %8d    ->  Candidate: %8d    (Delta: %+d allocs)\n",
		d.BaselineTotalAllocs, d.CandidateTotalAllocs, d.DeltaTotalAllocs))
	b.WriteString(fmt.Sprintf("  CPU Samples:   Baseline: %8d    ->  Candidate: %8d    (Delta: %+d samples)\n",
		d.BaselineTotalCPU, d.CandidateTotalCPU, d.DeltaTotalCPU))

	b.WriteString("\n" + bold + "ZERO-ALLOC INVARIANT VERDICT: " + reset)
	if d.ZeroAllocPassed {
		b.WriteString(green + "PASSED (0 regressions detected, zero-alloc bounds respected)\n" + reset)
	} else {
		b.WriteString(red + fmt.Sprintf("FAILED (%d regressions detected exceeding zero-alloc bounds)\n", len(d.Regressions)) + reset)
	}
	b.WriteString(bold + cyan + "======================================================================================================\n" + reset)

	return b.String()
}

// FormatJSON outputs the diff analysis as formatted JSON.
func (d *ProfileDiff) FormatJSON() ([]byte, error) {
	return json.MarshalIndent(d, "", "  ")
}
