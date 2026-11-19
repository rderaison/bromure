package delegation

// fallbacks are the streams the hub answers locally (no Bromure AC relay
// parked), and which one a newly parked relay is for. DelegationFallbacks.
//
// One park is one offer (the relay client dials its next slot only once
// that one is taken), so it's reserved for the one stream it kicks: a
// stream holding a call first (the oldest), else the oldest. The others
// keep their place and their wait.
type fallbacks struct {
	streams []*Watched // oldest first
	holding []*Watched // holding a call for a relay, in the order they started
}

func (f *fallbacks) add(s *Watched) { f.streams = append(f.streams, s) }

func (f *fallbacks) remove(s *Watched) {
	f.streams = without(f.streams, s)
	f.holding = without(f.holding, s)
}

func (f *fallbacks) hold(s *Watched) {
	if !contains(f.streams, s) || contains(f.holding, s) {
		return
	}
	f.holding = append(f.holding, s)
}

func (f *fallbacks) release(s *Watched) { f.holding = without(f.holding, s) }

// kick: a relay parked; the stream it's for, taken off the list (its shim
// reconnects onto it). nil: nobody's here.
func (f *fallbacks) kick() *Watched {
	var s *Watched
	switch {
	case len(f.holding) > 0:
		s = f.holding[0]
	case len(f.streams) > 0:
		s = f.streams[0]
	default:
		return nil
	}
	f.remove(s)
	return s
}

// kicked: whether a park picked s (it's no longer listed).
func (f *fallbacks) kicked(s *Watched) bool { return !contains(f.streams, s) }

func contains(list []*Watched, s *Watched) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func without(list []*Watched, s *Watched) []*Watched {
	out := list[:0]
	for _, x := range list {
		if x != s {
			out = append(out, x)
		}
	}
	return out
}
