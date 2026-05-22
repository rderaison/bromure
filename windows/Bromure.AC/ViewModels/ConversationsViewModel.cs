using System.Collections.ObjectModel;
using System.Text;
using System.Windows.Media;
using System.Windows.Threading;
using Bromure.AC.Mitm.Conversation;
using Bromure.AC.Mitm.Trace;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Audit 09 #2 surface. Lists every captured LLM exchange (traces
/// where <see cref="TraceRecord.IsConversation"/> is true) and
/// renders the most-recent into chat-style bubbles via
/// <see cref="ConversationParser"/>. Polls the TraceStore on a 3 s
/// timer — same indirection-via-poll pattern the trace inspector
/// uses, since the proxy hot path lives in a different thread.
/// </summary>
public sealed partial class ConversationsViewModel : ObservableObject
{
    private readonly TraceStore _store;
    private readonly IBodyEncryptor? _encryptor;
    private readonly DispatcherTimer _timer;

    public ObservableCollection<ConversationRowViewModel> Rows { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Messages))]
    [NotifyPropertyChangedFor(nameof(SelectedHasBody))]
    [NotifyPropertyChangedFor(nameof(SelectedProviderLabel))]
    [NotifyPropertyChangedFor(nameof(SelectedModel))]
    private ConversationRowViewModel? _selected;

    [ObservableProperty] private string _filter = "";

    public ConversationsViewModel(TraceStore store, IBodyEncryptor? encryptor = null)
    {
        _store = store;
        _encryptor = encryptor;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Refresh();
    }

    [RelayCommand]
    private void Refresh()
    {
        var recent = _store.Recent(limit: 200);
        var keep = new HashSet<Guid>();
        // Preserve selection across refreshes when possible.
        var selectedId = Selected?.Record.Id;
        Rows.Clear();
        foreach (var r in recent)
        {
            if (!r.IsConversation) continue;
            if (!string.IsNullOrEmpty(Filter)
                && !r.Host.Contains(Filter, StringComparison.OrdinalIgnoreCase)
                && !r.Path.Contains(Filter, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var row = new ConversationRowViewModel(r);
            Rows.Add(row);
            keep.Add(r.Id);
        }
        if (selectedId is { } id && keep.Contains(id))
        {
            Selected = Rows.FirstOrDefault(r => r.Record.Id == id);
        }
        else
        {
            Selected = Rows.FirstOrDefault();
        }
    }

    public bool SelectedHasBody => Selected?.Record.BodyStored == true;
    public string SelectedProviderLabel => ParsedSelection()?.Provider.ToString() ?? "";
    public string SelectedModel => ParsedSelection()?.Model ?? "";

    public IReadOnlyList<MessageBubbleViewModel> Messages
        => ParsedSelection() is { } convo
            ? convo.Messages
                .Where(m => m.Content.Count > 0)
                .Select(m => new MessageBubbleViewModel(m))
                .ToList()
            : Array.Empty<MessageBubbleViewModel>();

    private Conversation? _cachedConvo;
    private Guid _cachedConvoId;

    private Conversation? ParsedSelection()
    {
        if (Selected is null) return null;
        if (_cachedConvoId == Selected.Record.Id && _cachedConvo is not null) return _cachedConvo;
        var rec = Selected.Record;
        if (!rec.BodyStored) return null;
        var req = _store.LoadBody(rec, TraceStore.BodyKind.Request, _encryptor);
        var res = _store.LoadBody(rec, TraceStore.BodyKind.Response, _encryptor);
        _cachedConvo = ConversationParser.Parse(rec.Host, req, res);
        _cachedConvoId = rec.Id;
        return _cachedConvo;
    }
}

public sealed class ConversationRowViewModel
{
    public ConversationRowViewModel(TraceRecord r)
    {
        Record = r;
        Subtitle = $"{r.Host}{r.Path}";
        TimestampLocal = r.Timestamp.ToLocalTime().ToString("HH:mm:ss");
    }
    public TraceRecord Record { get; }
    public string Subtitle { get; }
    public string TimestampLocal { get; }
}

/// <summary>One rendered chat bubble. Role drives background tint;
/// the content is flattened to text/tool blocks for display.</summary>
public sealed class MessageBubbleViewModel
{
    public MessageBubbleViewModel(Message m)
    {
        Role = m.Role.ToString();
        Text = FlattenBlocks(m.Content);
        // Role-driven tint — matches the macOS port's bubble colours.
        Background = m.Role switch
        {
            Bromure.AC.Mitm.Conversation.Role.System => new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x33)),
            Bromure.AC.Mitm.Conversation.Role.User => new SolidColorBrush(Color.FromRgb(0x1B, 0x55, 0xBB)),
            Bromure.AC.Mitm.Conversation.Role.Assistant => new SolidColorBrush(Color.FromRgb(0x2A, 0x6F, 0x4B)),
            Bromure.AC.Mitm.Conversation.Role.Tool => new SolidColorBrush(Color.FromRgb(0x6F, 0x4D, 0x2A)),
            _ => new SolidColorBrush(Color.FromRgb(0x40, 0x40, 0x40)),
        };
        HorizontalAlignment = m.Role == Bromure.AC.Mitm.Conversation.Role.User
            ? System.Windows.HorizontalAlignment.Right
            : System.Windows.HorizontalAlignment.Left;
    }
    public string Role { get; }
    public string Text { get; }
    public Brush Background { get; }
    public System.Windows.HorizontalAlignment HorizontalAlignment { get; }

    private static string FlattenBlocks(IEnumerable<Block> blocks)
    {
        var sb = new StringBuilder();
        foreach (var b in blocks)
        {
            switch (b)
            {
                case Block.Text t:
                    if (sb.Length > 0) sb.Append('\n');
                    sb.Append(t.Value);
                    break;
                case Block.ToolUse tu:
                    if (sb.Length > 0) sb.Append('\n');
                    sb.Append("→ tool_use ").Append(tu.Name).Append('\n');
                    sb.Append(tu.Input);
                    break;
                case Block.ToolResult tr:
                    if (sb.Length > 0) sb.Append('\n');
                    sb.Append(tr.IsError ? "← tool_result (error)\n" : "← tool_result\n");
                    sb.Append(tr.Content);
                    break;
                case Block.Image img:
                    if (sb.Length > 0) sb.Append('\n');
                    sb.Append("[image ").Append(img.MediaType).Append(']');
                    break;
            }
        }
        return sb.ToString();
    }
}
