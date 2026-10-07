param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateDirectory,

    [int]$Radius = 512,

    [int]$Limit = 200
)

$source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

public static class CandidateProximity
{
    private static ulong[] Load(string path)
    {
        var values = new List<ulong>();
        foreach (string line in File.ReadLines(path))
        {
            ulong value;
            if (ulong.TryParse(line.Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out value))
                values.Add(value);
        }
        values.Sort();
        return values.ToArray();
    }

    private static int LowerBound(ulong[] values, ulong target)
    {
        int lo = 0, hi = values.Length;
        while (lo < hi)
        {
            int mid = lo + ((hi - lo) / 2);
            if (values[mid] < target) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    public static string[] Find(string directory, int radius, int limit)
    {
        var hpFiles = new[] { "hp_i32.txt", "hp_f32.txt" };
        var mpFiles = new[] { "mp_i32.txt", "mp_f32.txt" };
        var lifeFiles = new[] { "lives_i32.txt", "lives_f32.txt" };
        var output = new List<string>();

        foreach (string hpFile in hpFiles)
        foreach (string mpFile in mpFiles)
        foreach (string lifeFile in lifeFiles)
        {
            ulong[] hp = Load(Path.Combine(directory, hpFile));
            ulong[] mp = Load(Path.Combine(directory, mpFile));
            ulong[] lives = Load(Path.Combine(directory, lifeFile));

            foreach (ulong h in hp)
            {
                ulong low = h > (ulong)radius ? h - (ulong)radius : 0;
                ulong high = h + (ulong)radius;
                int mi = LowerBound(mp, low);
                while (mi < mp.Length && mp[mi] <= high)
                {
                    ulong m = mp[mi++];
                    ulong pairLow = Math.Min(h, m);
                    pairLow = pairLow > (ulong)radius ? pairLow - (ulong)radius : 0;
                    ulong pairHigh = Math.Max(h, m) + (ulong)radius;
                    int li = LowerBound(lives, pairLow);
                    while (li < lives.Length && lives[li] <= pairHigh)
                    {
                        ulong l = lives[li++];
                        output.Add(String.Format(CultureInfo.InvariantCulture,
                            "{0,-7} 0x{1:X16} | {2,-7} 0x{3:X16} | {4,-10} 0x{5:X16}",
                            Path.GetFileNameWithoutExtension(hpFile), h,
                            Path.GetFileNameWithoutExtension(mpFile), m,
                            Path.GetFileNameWithoutExtension(lifeFile), l));
                        if (output.Count >= limit)
                            return output.ToArray();
                    }
                }
            }
        }

        return output.ToArray();
    }
}
'@

if (-not ('CandidateProximity' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

[CandidateProximity]::Find($CandidateDirectory, $Radius, $Limit)
