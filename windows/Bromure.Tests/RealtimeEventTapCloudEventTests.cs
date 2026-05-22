using System.Text;
using System.Text.Json.Nodes;
using Bromure.AC.Mitm.WebSocket;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 02 gap #2: RealtimeEventTap counted response.completed
/// but never emitted a cloud audit event, so realtime streaming
/// sessions never landed in the dashboard. The earlier "tests pass"
/// status was unit coverage that didn't observe the emit path.
/// These tests pin the emission contract.
/// </summary>
public class RealtimeEventTapCloudEventTests
{
    [Fact]
    public void Handle_ResponseCompleted_FiresLlmRequestEvent()
    {
        Guid? capturedProfile = null;
        string? capturedType = null;
        JsonObject? capturedData = null;
        var tap = new RealtimeEventTap(
            profileId: Guid.NewGuid(),
            host: "api.openai.com",
            path: "/v1/realtime",
            statusCode: 101,
            log: null,
            onCloudEvent: (pid, type, data) =>
            {
                capturedProfile = pid;
                capturedType = type;
                capturedData = data;
            });

        var msg = MakeMessage("""
            {
              "type": "response.completed",
              "response": {
                "id": "resp_abc",
                "model": "gpt-realtime",
                "usage": { "input_tokens": 42, "output_tokens": 17 }
              }
            }
            """);
        tap.Handle(msg);

        tap.StreamedAnyEvents.Should().BeTrue();
        capturedType.Should().Be("llm.request");
        capturedData.Should().NotBeNull();
        capturedData!["host"]!.GetValue<string>().Should().Be("api.openai.com");
        capturedData["model"]!.GetValue<string>().Should().Be("gpt-realtime");
        capturedData["response_id"]!.GetValue<string>().Should().Be("resp_abc");
        capturedData["input_tokens"]!.GetValue<int>().Should().Be(42);
        capturedData["output_tokens"]!.GetValue<int>().Should().Be(17);
    }

    [Fact]
    public void Handle_OtherEventType_DoesNotFire()
    {
        var fired = false;
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com", "/v1/realtime", 101,
            onCloudEvent: (_, _, _) => fired = true);
        tap.Handle(MakeMessage("""{"type":"response.audio.delta","delta":"abc"}"""));
        tap.Handle(MakeMessage("""{"type":"session.created"}"""));
        fired.Should().BeFalse();
        tap.StreamedAnyEvents.Should().BeFalse();
    }

    [Fact]
    public void Handle_NoCallback_DoesNotThrow()
    {
        // Earlier wiring path: tap created without a callback (test
        // harness / pre-wire path). Must continue to count + log
        // without exploding.
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com", "/v1/realtime", 101);
        tap.Handle(MakeMessage("""{"type":"response.completed","response":{"id":"x"}}"""));
        tap.StreamedAnyEvents.Should().BeTrue();
    }

    [Fact]
    public void Handle_MalformedJson_NoOp()
    {
        var fired = false;
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com", "/v1/realtime", 101,
            onCloudEvent: (_, _, _) => fired = true);
        tap.Handle(MakeMessage("not json at all"));
        fired.Should().BeFalse();
    }

    [Fact]
    public void Handle_BinaryMessage_NoOp()
    {
        var fired = false;
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com", "/v1/realtime", 101,
            onCloudEvent: (_, _, _) => fired = true);
        tap.Handle(new WsMessageAssembler.Message(
            WsMessageAssembler.MessageKind.Binary, new byte[] { 1, 2, 3 }));
        fired.Should().BeFalse();
    }

    private static WsMessageAssembler.Message MakeMessage(string json)
        => new(WsMessageAssembler.MessageKind.Text, Encoding.UTF8.GetBytes(json));
}
