namespace Bromure.AC.Mitm.Swap;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/CompromiseDetector.swift</c>'s
/// Aho-Corasick automaton. One scan over the input stream finds every
/// pattern occurrence in O(n + total-output-size). Built once per
/// <see cref="TokenSwapper.SetMap"/>; re-used for every outgoing request
/// in the session — important because we scan both headers AND body on
/// every request and don't want to do <c>entries.Count</c> substring
/// searches per call.
/// </summary>
public sealed class AhoCorasick
{
    private struct Node
    {
        public Dictionary<byte, int> Children;
        public int Fail;
        public List<int> Outputs;
    }

    private readonly Node[] _nodes;
    public int PatternCount { get; }

    /// <summary>
    /// Build the automaton from <paramref name="patterns"/>. Empty /
    /// duplicate patterns are silently dropped — they would pin the
    /// root state and emit a match on every byte.
    /// </summary>
    public AhoCorasick(IReadOnlyList<byte[]> patterns)
    {
        var nodes = new List<Node>
        {
            new() { Children = new Dictionary<byte, int>(), Fail = 0, Outputs = new List<int>() },
        };
        var seen = new HashSet<string>();
        var keptCount = 0;

        for (var idx = 0; idx < patterns.Count; idx++)
        {
            var pat = patterns[idx];
            if (pat.Length == 0) continue;
            var key = Convert.ToHexString(pat);
            if (!seen.Add(key)) continue;

            var cur = 0;
            foreach (var b in pat)
            {
                if (nodes[cur].Children.TryGetValue(b, out var next))
                {
                    cur = next;
                }
                else
                {
                    nodes.Add(new Node
                    {
                        Children = new Dictionary<byte, int>(),
                        Fail = 0,
                        Outputs = new List<int>(),
                    });
                    var newIdx = nodes.Count - 1;
                    nodes[cur].Children[b] = newIdx;
                    cur = newIdx;
                }
            }
            nodes[cur].Outputs.Add(idx);
            keptCount++;
        }

        // BFS for fail links + propagate outputs along the fail chain.
        var queue = new Queue<int>();
        foreach (var (_, child) in nodes[0].Children)
        {
            // Capture-by-value: structs in List<T> are mutated through
            // the indexer; reassign after edit.
            var c = nodes[child]; c.Fail = 0; nodes[child] = c;
            queue.Enqueue(child);
        }
        while (queue.Count > 0)
        {
            var u = queue.Dequeue();
            foreach (var (b, v) in nodes[u].Children.ToArray())
            {
                queue.Enqueue(v);
                var f = nodes[u].Fail;
                while (f != 0 && !nodes[f].Children.ContainsKey(b))
                {
                    f = nodes[f].Fail;
                }
                var target = nodes[f].Children.TryGetValue(b, out var t) ? t : 0;
                var fail = (target == v) ? 0 : target;
                var nv = nodes[v];
                nv.Fail = fail;
                if (nodes[fail].Outputs.Count > 0)
                {
                    nv.Outputs.AddRange(nodes[fail].Outputs);
                }
                nodes[v] = nv;
            }
        }

        _nodes = nodes.ToArray();
        PatternCount = keptCount;
    }

    /// <summary>
    /// Scan <paramref name="data"/> and return the set of pattern indices
    /// that appeared at least once. Index space matches the original
    /// patterns array passed to the ctor; empty/duplicate inputs were
    /// dropped at construction.
    /// </summary>
    public HashSet<int> Scan(ReadOnlySpan<byte> data)
    {
        var found = new HashSet<int>();
        if (PatternCount == 0 || data.Length == 0) return found;
        var state = 0;
        foreach (var b in data)
        {
            while (state != 0 && !_nodes[state].Children.ContainsKey(b))
            {
                state = _nodes[state].Fail;
            }
            if (_nodes[state].Children.TryGetValue(b, out var next))
            {
                state = next;
            }
            var outs = _nodes[state].Outputs;
            if (outs.Count > 0)
            {
                foreach (var idx in outs) found.Add(idx);
            }
        }
        return found;
    }
}
