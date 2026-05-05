using System.Text;
using YamlDotNet.RepresentationModel;

namespace Bromure.AC.Core.Imports;

/// <summary>
/// Port of <c>Sources/AgentCoding/KubeconfigImport.swift</c>.
/// Parses a kubectl kubeconfig YAML into one <see cref="KubeconfigEntry"/>
/// per context. <c>current-context</c> is preserved by listing it first.
/// </summary>
public static class KubeconfigImport
{
    public sealed class ImportException : Exception
    {
        public ImportException(string msg) : base(msg) { }
    }

    public static IReadOnlyList<KubeconfigEntry> Parse(string yamlText)
    {
        if (string.IsNullOrWhiteSpace(yamlText))
        {
            throw new ImportException("file is empty");
        }
        var stream = new YamlStream();
        try { stream.Load(new StringReader(yamlText)); }
        catch (Exception ex)
        {
            throw new ImportException($"Couldn't parse the YAML: {ex.Message}");
        }
        if (stream.Documents.Count == 0)
        {
            throw new ImportException("file is empty");
        }
        if (stream.Documents[0].RootNode is not YamlMappingNode top)
        {
            throw new ImportException("top level isn't a mapping");
        }

        var clustersByName = IndexNamedList(top, "clusters", "cluster");
        var usersByName = IndexNamedList(top, "users", "user");
        var contexts = top.Children.TryGetValue(new YamlScalarNode("contexts"), out var c) && c is YamlSequenceNode seq
            ? seq.Children.OfType<YamlMappingNode>().ToList()
            : new List<YamlMappingNode>();

        string? currentContext = null;
        if (top.Children.TryGetValue(new YamlScalarNode("current-context"), out var cc) && cc is YamlScalarNode cs)
        {
            currentContext = cs.Value;
        }

        var entries = new List<KubeconfigEntry>();
        foreach (var ctxMap in contexts)
        {
            if (!Try(ctxMap, "name", out string? name) || name is null) continue;
            if (!ctxMap.Children.TryGetValue(new YamlScalarNode("context"), out var inner)
                || inner is not YamlMappingNode innerMap) continue;

            var clusterName = ScalarOrEmpty(innerMap, "cluster");
            var userName = ScalarOrEmpty(innerMap, "user");
            var ns = ScalarOrEmpty(innerMap, "namespace");

            var cluster = clustersByName.GetValueOrDefault(clusterName);
            var user = usersByName.GetValueOrDefault(userName);

            var server = cluster is null ? "" : ScalarOrEmpty(cluster, "server");
            var caPem = (cluster is null
                ? null
                : DecodeBase64Field(cluster, "certificate-authority-data")
                  ?? ReadFileField(cluster, "certificate-authority"))
                ?? "";

            var auth = user is null ? KubeconfigEntry.Auth.BearerToken("") : ParseAuth(user);

            entries.Add(new KubeconfigEntry(
                Name: name,
                ServerUrl: server,
                CaCertPem: caPem,
                Namespace: ns,
                AuthSpec: auth));
        }

        if (currentContext is not null)
        {
            var idx = entries.FindIndex(e => e.Name == currentContext);
            if (idx > 0)
            {
                var item = entries[idx];
                entries.RemoveAt(idx);
                entries.Insert(0, item);
            }
        }

        return entries;
    }

    private static Dictionary<string, YamlMappingNode> IndexNamedList(YamlMappingNode top, string outerKey, string innerKey)
    {
        var result = new Dictionary<string, YamlMappingNode>(StringComparer.Ordinal);
        if (!top.Children.TryGetValue(new YamlScalarNode(outerKey), out var raw)
            || raw is not YamlSequenceNode list) return result;
        foreach (var item in list.Children.OfType<YamlMappingNode>())
        {
            if (!Try(item, "name", out string? name) || name is null) continue;
            if (!item.Children.TryGetValue(new YamlScalarNode(innerKey), out var inner)
                || inner is not YamlMappingNode innerMap) continue;
            result[name] = innerMap;
        }
        return result;
    }

    private static KubeconfigEntry.Auth ParseAuth(YamlMappingNode user)
    {
        if (Try(user, "token", out string? token) && !string.IsNullOrEmpty(token))
        {
            return KubeconfigEntry.Auth.BearerToken(token!);
        }
        var cert = DecodeBase64Field(user, "client-certificate-data")
                   ?? ReadFileField(user, "client-certificate");
        var key = DecodeBase64Field(user, "client-key-data")
                  ?? ReadFileField(user, "client-key");
        if (!string.IsNullOrEmpty(cert) && !string.IsNullOrEmpty(key))
        {
            return KubeconfigEntry.Auth.ClientCert(cert!, key!);
        }
        if (user.Children.TryGetValue(new YamlScalarNode("exec"), out var execNode)
            && execNode is YamlMappingNode execMap
            && Try(execMap, "command", out string? cmd) && !string.IsNullOrEmpty(cmd))
        {
            var args = new List<string>();
            if (execMap.Children.TryGetValue(new YamlScalarNode("args"), out var argsNode)
                && argsNode is YamlSequenceNode argsSeq)
            {
                foreach (var a in argsSeq.Children.OfType<YamlScalarNode>())
                {
                    if (a.Value is not null) args.Add(a.Value);
                }
            }
            return KubeconfigEntry.Auth.ExecPlugin(cmd!, args, refreshSeconds: 600);
        }
        return KubeconfigEntry.Auth.BearerToken("");
    }

    private static string? DecodeBase64Field(YamlMappingNode node, string key)
    {
        if (!Try(node, key, out string? s) || string.IsNullOrEmpty(s)) return null;
        try
        {
            var bytes = Convert.FromBase64String(s!);
            return Encoding.UTF8.GetString(bytes);
        }
        catch (FormatException) { return null; }
    }

    private static string? ReadFileField(YamlMappingNode node, string key)
    {
        if (!Try(node, key, out string? path) || string.IsNullOrEmpty(path)) return null;
        var expanded = Environment.ExpandEnvironmentVariables(path!);
        if (expanded.StartsWith("~/", StringComparison.Ordinal))
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            expanded = Path.Combine(home, expanded[2..]);
        }
        try { return File.ReadAllText(expanded); }
        catch { return null; }
    }

    private static string ScalarOrEmpty(YamlMappingNode node, string key)
        => Try(node, key, out string? v) ? v ?? "" : "";

    private static bool Try(YamlMappingNode node, string key, out string? value)
    {
        if (node.Children.TryGetValue(new YamlScalarNode(key), out var n) && n is YamlScalarNode scalar)
        {
            value = scalar.Value;
            return true;
        }
        value = null;
        return false;
    }
}

public sealed record KubeconfigEntry(
    string Name,
    string ServerUrl,
    string CaCertPem,
    string Namespace,
    KubeconfigEntry.Auth AuthSpec)
{
    public abstract record Auth
    {
        public sealed record BearerTokenAuth(string Token) : Auth;
        public sealed record ClientCertAuth(string CertPem, string KeyPem) : Auth;
        public sealed record ExecPluginAuth(string Command, IReadOnlyList<string> Args, int RefreshSeconds) : Auth;

        public static Auth BearerToken(string token) => new BearerTokenAuth(token);
        public static Auth ClientCert(string cert, string key) => new ClientCertAuth(cert, key);
        public static Auth ExecPlugin(string cmd, IReadOnlyList<string> args, int refreshSeconds)
            => new ExecPluginAuth(cmd, args, refreshSeconds);
    }
}
