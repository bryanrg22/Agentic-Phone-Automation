# Gemini Integration Setup

## Recommended Model

**Gemini 2.5 Flash-Lite** (`gemini-2.5-flash-lite`) — fastest and cheapest multimodal model. Best for our use case (screenshots + short JSON responses).

| Model | Speed | Image Input | Text Output | Best For |
|-------|-------|------------|-------------|----------|
| `gemini-2.5-flash-lite` | Fastest | $0.10/1M tokens | $0.40/1M tokens | Our use case (speed + cost) |
| `gemini-3-flash-preview` | Fast | $0.30/1M tokens | $2.50/1M tokens | Better accuracy, still fast |
| `gemini-3.1-flash-lite-preview` | Fast | TBD (preview) | TBD (preview) | Newest, may be best |
| `gemini-2.5-pro` | Slow | $1.25/1M tokens | $10.00/1M tokens | Complex reasoning (overkill) |

## API Key Setup

1. Go to https://aistudio.google.com/apikey
2. Create a new API key
3. Add to `.env`:
```
GEMINI_API_KEY=your_key_here
```

## Code Integration

Gemini uses the same OpenAI-compatible chat completions format. The API endpoint is different:

```javascript
// Instead of:
const resp = await fetch('https://api.openai.com/v1/chat/completions', {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ model: 'gpt-5.4-mini', messages, tools, tool_choice: 'auto' }),
});

// Use:
const resp = await fetch('https://generativelanguage.googleapis.com/v1beta/openai/chat/completions', {
  method: 'POST',
  headers: { 'Authorization': `Bearer ${geminiApiKey}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ model: 'gemini-2.5-flash-lite', messages, tools, tool_choice: 'auto' }),
});
```

Gemini supports the OpenAI-compatible endpoint at:
```
https://generativelanguage.googleapis.com/v1beta/openai/chat/completions
```

This means minimal code changes — just swap the URL and API key. The message format (with `image_url`, `tool_calls`, etc.) stays the same.

## Alternative: Native Gemini API

If the OpenAI-compatible endpoint doesn't support all features (like tool calling), use the native API:

```javascript
const resp = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=${geminiApiKey}`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    contents: [{
      parts: [
        { text: systemPrompt },
        { inline_data: { mime_type: 'image/png', data: base64Screenshot } },
        { text: 'What action should I take?' }
      ]
    }],
    tools: [{
      function_declarations: toolDefs  // same format as OpenAI
    }],
  }),
});
```

## Implementation Plan

When ready to switch:
1. Add `GEMINI_API_KEY` to `.env`
2. In `agent.mjs`, add `--provider gemini` flag
3. If `--provider gemini`: swap the API URL and key in `callLLM()`
4. Model defaults to `gemini-2.5-flash-lite` for Gemini
5. Everything else (tools, messages, screenshots) stays the same

## Key Differences from OpenAI

- Tool calling format is compatible via the OpenAI-compatible endpoint
- Image handling: same base64 format works
- Rate limits may differ
- Response format is identical (choices[0].message.content / tool_calls)
- No `max_tokens` parameter needed (Gemini auto-determines)
