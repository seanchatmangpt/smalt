// Package fastmetrics provides zero-heap-allocation metric vectors and
// Prometheus scrapers for the POSH membrane hot path.
package fastmetrics

import (
	"bytes"
	"io"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
)

// Series represents an individual time series with a pre-rendered Prometheus
// text line prefix and an atomic counter.
type Series struct {
	prefix []byte // e.g., []byte("posh_requests_total{code=\"OK\",op=\"echo\",transport=\"uds\"} ")
	labels []Label
	val    atomic.Uint64
}

// Inc increments the counter by 1. Zero heap allocations.
func (s *Series) Inc() {
	s.val.Add(1)
}

// Add increments the counter by delta. Zero heap allocations.
func (s *Series) Add(delta uint64) {
	s.val.Add(delta)
}

// Load returns the current counter value.
func (s *Series) Load() uint64 {
	return s.val.Load()
}

// Labels returns the registered labels for this series.
func (s *Series) Labels() []Label {
	return s.labels
}

// Prefix returns the pre-rendered prefix for this series.
func (s *Series) Prefix() []byte {
	return s.prefix
}

// Vector represents a Prometheus metric vector with fixed or dynamically
// registered label combinations, maintaining pre-rendered prefixes for
// zero-allocation scraping.
type Vector struct {
	mu         sync.RWMutex
	name       string
	help       string
	typeHeader []byte
	seriesMap  map[string]*Series
	seriesList []*Series
}

// NewVector constructs a new Vector. The `# TYPE <name> counter\n` header
// is pre-rendered once at initialization.
func NewVector(name string, help string) *Vector {
	header := []byte("# TYPE " + name + " counter\n")
	return &Vector{
		name:       name,
		help:       help,
		typeHeader: header,
		seriesMap:  make(map[string]*Series),
		seriesList: make([]*Series, 0),
	}
}

// Label represents a key-value label pair.
type Label struct {
	Key   string
	Value string
}

// FormatPrefix builds the deterministic Prometheus line prefix for a metric
// name and sorted label pairs: `name{k1="v1",k2="v2"} `
func FormatPrefix(name string, labels []Label) []byte {
	// Sort labels by key for Prometheus deterministic output
	sorted := make([]Label, len(labels))
	copy(sorted, labels)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Key < sorted[j].Key
	})

	var buf bytes.Buffer
	buf.WriteString(name)
	if len(sorted) > 0 {
		buf.WriteByte('{')
		for i, l := range sorted {
			if i > 0 {
				buf.WriteByte(',')
			}
			buf.WriteString(l.Key)
			buf.WriteString(`="`)
			// Escape quotes or backslashes if any
			for j := 0; j < len(l.Value); j++ {
				switch l.Value[j] {
				case '\\', '"':
					buf.WriteByte('\\')
				}
				buf.WriteByte(l.Value[j])
			}
			buf.WriteByte('"')
		}
		buf.WriteByte('}')
	}
	buf.WriteByte(' ')
	return buf.Bytes()
}

// RegisterSeries pre-registers a series with the given label set and returns
// the Series pointer for zero-allocation increments on the hot path.
func (v *Vector) RegisterSeries(labels ...Label) *Series {
	v.mu.Lock()
	defer v.mu.Unlock()

	prefix := FormatPrefix(v.name, labels)
	key := string(prefix)

	if s, ok := v.seriesMap[key]; ok {
		return s
	}

	s := &Series{
		prefix: prefix,
		labels: labels,
	}
	v.seriesMap[key] = s
	v.seriesList = append(v.seriesList, s)

	// Sort series list deterministically by prefix bytes
	sort.Slice(v.seriesList, func(i, j int) bool {
		return bytes.Compare(v.seriesList[i].prefix, v.seriesList[j].prefix) < 0
	})

	return s
}

// GetOrRegister returns an existing series matching the labels or registers
// a new one.
func (v *Vector) GetOrRegister(labels ...Label) *Series {
	prefix := FormatPrefix(v.name, labels)
	key := string(prefix)

	v.mu.RLock()
	s, ok := v.seriesMap[key]
	v.mu.RUnlock()
	if ok {
		return s
	}

	return v.RegisterSeries(labels...)
}

// Name returns the metric name.
func (v *Vector) Name() string {
	return v.name
}

// Help returns the help text for the metric.
func (v *Vector) Help() string {
	return v.help
}

// SeriesList returns a snapshot of all registered Series.
func (v *Vector) SeriesList() []*Series {
	v.mu.RLock()
	defer v.mu.RUnlock()
	res := make([]*Series, len(v.seriesList))
	copy(res, v.seriesList)
	return res
}

// AppendRender appends the vector's Prometheus text format lines to dst
// without heap allocations, returning the expanded slice.
func (v *Vector) AppendRender(dst []byte) []byte {
	v.mu.RLock()
	defer v.mu.RUnlock()

	if len(v.seriesList) == 0 {
		return dst
	}

	dst = append(dst, v.typeHeader...)
	for _, s := range v.seriesList {
		dst = append(dst, s.prefix...)
		dst = strconv.AppendUint(dst, s.val.Load(), 10)
		dst = append(dst, '\n')
	}
	return dst
}

// WriteRender writes the Prometheus text output directly to an io.Writer
// using a pooled scratch buffer to guarantee zero allocations.
func (v *Vector) WriteRender(w io.Writer) error {
	bufPtr := scrapeBufPool.Get().(*[]byte)
	buf := (*bufPtr)[:0]
	buf = v.AppendRender(buf)
	_, err := w.Write(buf)
	*bufPtr = buf
	scrapeBufPool.Put(bufPtr)
	return err
}

var scrapeBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, 0, 16384)
		return &b
	},
}

// FastRegistry aggregates multiple zero-alloc metric vectors and serves them
// with zero heap allocations on scrape.
type FastRegistry struct {
	mu      sync.RWMutex
	vectors []*Vector
}

// NewRegistry creates a new FastRegistry.
func NewRegistry() *FastRegistry {
	return &FastRegistry{
		vectors: make([]*Vector, 0),
	}
}

// Register adds a Vector to the registry.
func (r *FastRegistry) Register(v *Vector) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.vectors = append(r.vectors, v)
	sort.Slice(r.vectors, func(i, j int) bool {
		return r.vectors[i].name < r.vectors[j].name
	})
}

// Vectors returns a snapshot of all registered Vectors.
func (r *FastRegistry) Vectors() []*Vector {
	r.mu.RLock()
	defer r.mu.RUnlock()
	res := make([]*Vector, len(r.vectors))
	copy(res, r.vectors)
	return res
}

// AppendRender renders all registered vectors to dst.
func (r *FastRegistry) AppendRender(dst []byte) []byte {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, v := range r.vectors {
		dst = v.AppendRender(dst)
	}
	return dst
}

// WriteRender renders all metrics to w using a pooled zero-alloc buffer.
func (r *FastRegistry) WriteRender(w io.Writer) error {
	bufPtr := scrapeBufPool.Get().(*[]byte)
	buf := (*bufPtr)[:0]
	buf = r.AppendRender(buf)
	_, err := w.Write(buf)
	*bufPtr = buf
	scrapeBufPool.Put(bufPtr)
	return err
}
