namespace Bromure.Platform;

/// <summary>
/// Tiny semver-ish comparator. Returns -1/0/+1 like IComparable.
/// Used by HttpAppUpdater (audit 08) to decide whether the appcast
/// manifest's version trumps the running build. Pre-release suffixes
/// ("1.2.3-rc1") sort before the same MAJOR.MINOR.PATCH release;
/// non-numeric segments fall back to lexical comparison.
/// </summary>
public static class SemverCompare
{
    public static int Compare(string a, string b)
    {
        var sa = a.Split('-')[0].Split('.');
        var sb = b.Split('-')[0].Split('.');
        int n = Math.Max(sa.Length, sb.Length);
        for (int i = 0; i < n; i++)
        {
            var ai = i < sa.Length ? sa[i] : "0";
            var bi = i < sb.Length ? sb[i] : "0";
            if (int.TryParse(ai, out var ax) && int.TryParse(bi, out var bx))
            {
                if (ax != bx) return ax.CompareTo(bx);
            }
            else
            {
                var c = string.Compare(ai, bi, StringComparison.OrdinalIgnoreCase);
                if (c != 0) return c;
            }
        }
        // Same numeric trunk — a pre-release tag loses to a clean release.
        var aHasTag = a.Contains('-');
        var bHasTag = b.Contains('-');
        if (aHasTag && !bHasTag) return -1;
        if (!aHasTag && bHasTag) return 1;
        return 0;
    }
}
