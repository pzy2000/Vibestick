using System.Globalization;
using System.Text.RegularExpressions;

namespace Vibestick.Core;

public static partial class PowerCfgParser
{
    private static readonly Regex GuidRegex = new(
        @"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        RegexOptions.Compiled);

    public static string ParseFirstGuid(string text)
    {
        var match = GuidRegex.Match(text);
        if (!match.Success)
        {
            throw new FormatException("No GUID was found in powercfg output.");
        }

        return match.Value.ToLowerInvariant();
    }

    public static PowerPolicySnapshot ParseLidActionSnapshot(string schemeGuid, string text)
    {
        return new PowerPolicySnapshot(
            schemeGuid.ToLowerInvariant(),
            ParsePowerIndex(text, isAc: true),
            ParsePowerIndex(text, isAc: false));
    }

    private static int ParsePowerIndex(string text, bool isAc)
    {
        var patterns = isAc
            ? new[]
            {
                @"Current\s+AC\s+Power\s+Setting\s+Index\s*:\s*0x([0-9a-fA-F]+)",
                @"当前交流电源设置索引\s*:\s*0x([0-9a-fA-F]+)"
            }
            : new[]
            {
                @"Current\s+DC\s+Power\s+Setting\s+Index\s*:\s*0x([0-9a-fA-F]+)",
                @"当前直流电源设置索引\s*:\s*0x([0-9a-fA-F]+)"
            };

        foreach (var pattern in patterns)
        {
            var match = Regex.Match(text, pattern, RegexOptions.IgnoreCase);
            if (match.Success)
            {
                return int.Parse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            }
        }

        var fallbackMatches = Regex.Matches(text, @"0x([0-9a-fA-F]+)", RegexOptions.IgnoreCase);
        if (fallbackMatches.Count >= 2)
        {
            var fallbackIndex = isAc ? 0 : 1;
            return int.Parse(
                fallbackMatches[fallbackIndex].Groups[1].Value,
                NumberStyles.HexNumber,
                CultureInfo.InvariantCulture);
        }

        var powerKind = isAc ? "AC" : "DC";
        throw new FormatException($"Could not parse current {powerKind} lid action from powercfg output.");
    }
}
