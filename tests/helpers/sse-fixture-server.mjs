// Offline fixture for tests/Test-GatewayStream.ps1: a local server that answers like the gateway.
//   POST .../progressive  stream:true  -> 30 server-sent events 60 ms apart (message_start ... message_stop)
//   POST .../buffered     stream:true  -> the same events in one write after 600 ms
//   POST .../nostop       stream:true  -> events 60 ms apart without message_stop
//   model "denied-model"               -> 403 Anthropic-shaped error
//   stream:false                       -> 200 application/json message
// Usage: node tests/helpers/sse-fixture-server.mjs <port>
import http from "node:http";

const port = Number(process.argv[2]);
const sse = (type, data) => `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

http
  .createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", async () => {
      const body = JSON.parse(raw || "{}");
      const headers = { "x-ccof-request-id": "00000000-0000-0000-0000-000000000001" };
      if (body.model === "denied-model") {
        res.writeHead(403, { ...headers, "content-type": "application/json" });
        res.end(JSON.stringify({ type: "error", error: { type: "permission_error", message: "denied" } }));
        return;
      }
      if (!body.stream) {
        res.writeHead(200, { ...headers, "content-type": "application/json" });
        res.end(JSON.stringify({ type: "message", usage: { input_tokens: 14, output_tokens: 4 } }));
        return;
      }
      const events = [sse("message_start", { type: "message_start", message: { usage: { input_tokens: 14, output_tokens: 1 } } })];
      for (let i = 0; i < 30; i++) events.push(sse("content_block_delta", { type: "content_block_delta", delta: { type: "text_delta", text: `${i}\n` } }));
      events.push(sse("message_delta", { type: "message_delta", usage: { output_tokens: 61 } }));
      if (!req.url.includes("nostop")) events.push(sse("message_stop", { type: "message_stop" }));
      res.writeHead(200, { ...headers, "content-type": "text/event-stream" });
      if (req.url.includes("buffered")) {
        await pause(600);
        res.end(events.join(""));
        return;
      }
      for (const event of events) {
        res.write(event);
        await pause(60);
      }
      res.end();
    });
  })
  .listen(port, "127.0.0.1");
