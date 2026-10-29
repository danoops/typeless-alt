export default {
  async fetch(request, env) {
    if (request.method !== "POST") return new Response("POST required", { status: 405 });
    if (!env.WORKER_SECRET || request.headers.get("Authorization") !== `Bearer ${env.WORKER_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }
    // Bound input before decoding. Never log dictation or credentials.
    const reader = request.body?.getReader();
    if (!reader) return new Response("Missing body", { status: 400 });
    let size = 0;
    const chunks = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 64000) { await reader.cancel(); return new Response("Too large", { status: 413 }); }
      chunks.push(value);
    }
    let body;
    try {
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      body = JSON.parse(new TextDecoder().decode(bytes));
    } catch { return new Response("Invalid JSON", { status: 400 }); }
    if (!Array.isArray(body.messages) || body.messages.length !== 2 ||
        body.messages.some(m => !["system", "user"].includes(m.role) || typeof m.content !== "string")) {
      return new Response("Invalid messages", { status: 400 });
    }
    try {
      const result = await env.AI.run("@cf/qwen/qwen3-30b-a3b-fp8", {
        messages: body.messages,
        max_tokens: 4096,
        temperature: 0.2,
        stream: false,
      });
      const choice = result.choices?.[0];
      if (choice?.finish_reason && choice.finish_reason !== "stop") return new Response("Incomplete result", { status: 502 });
      const text = result.response ?? choice?.message?.content;
      if (typeof text !== "string") return new Response("Invalid model response", { status: 502 });
      return Response.json({ response: text }, { headers: { "Cache-Control": "no-store" } });
    } catch { return new Response("Workers AI unavailable", { status: 502 }); }
  },
};
