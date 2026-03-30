# Research Findings — Coordinate Accuracy & Screenshot Optimization

## Key Finding 1: Higher Resolution Does NOT Help GUI Agents

**Source:** ScreenSpot-Pro (2025), OSWorld (NeurIPS 2024)

- Higher resolutions exceed the effective handling capacity of current multimodal LLMs
- Increased resolution = smaller relative target sizes = **worse grounding accuracy**
- ScreenSpot-Pro: GPT-4o scores **0.8%** on high-res professional GUIs where targets occupy just 0.07% of screen area
- Both OpenAI and Anthropic **internally resize** images before processing (OpenAI: 768px shortest side, Anthropic: 1568px longest edge)
- Sending full Retina screenshots (8MB) wastes upload time — the API throws away the extra pixels anyway

**Implication for our system:** Resize phone screenshots from 1179×2556 (8MB) to ~768×1664 (~150KB JPEG). Same AI accuracy, 50x smaller file, 5-10x faster response.

## Key Finding 2: Coordinate Prediction is the #1 Failure Mode

**Source:** A3 Android Agent Arena, GUI-Actor (NeurIPS 2025), OSWorld

- "Perform CLICK at wrong coordinate" is the **most frequent error** in mobile GUI agents
- Three structural causes:
  1. **Weak spatial-semantic alignment** — LLMs have no spatial inductive bias
  2. **Ambiguous supervision** — many valid tap positions exist on a button, but training treats it as single-point
  3. **Granularity mismatch** — Vision Transformers operate at coarse patch-level, not pixel-level
- Icon grounding is **dramatically harder** than text grounding (many models score <5% on icons vs reasonable text accuracy)
- VLMs exhibit **systematic directional biases** — not random errors but structured localization hallucinations

## Key Finding 3: Alternatives to Raw Coordinate Prediction

### Set-of-Marks (SoM) / OmniParser — Microsoft
- Overlay numbered labels on detected UI elements
- AI picks an ID instead of guessing coordinates
- **GPT-4o accuracy: 0.8% → 39.6%** with OmniParser on ScreenSpot-Pro
- Most production-ready approach

### ZoomClick — Princeton AI Lab
- Training-free iterative zoom: predict rough area → crop → zoom 2-3x → predict again
- **+48.8 percentage points** accuracy improvement on ScreenSpot-Pro
- Works with any model, no training needed
- Best for small/dense targets

### Grid Overlay — AppAgent (Tencent)
- Draw grid lines on screenshot for spatial reference
- AI uses grid intersections to estimate coordinates more accurately
- Used as fallback when element detection fails
- Low overhead (~30ms per image)

### Accessibility Tree Grounding
- Use view hierarchy identifiers instead of coordinates
- **Eliminates coordinate error entirely** for elements with proper a11y markup
- Limitation: many apps have incomplete/incorrect accessibility annotations
- We already implement this via getUIElements + tapText

### Two-Model Approach — ClickAgent (Samsung)
- Separate planning model (GPT) from grounding model (TinyClick)
- **72% task success vs 14%** for single-model approach (5x improvement)

## Key Finding 4: Verification Loops Transform Accuracy

**Source:** Manus agent, general agent harness literature

- **83% per-step accuracy → 96%+ task completion** with verification loops
- Pattern: capture screenshot → execute action → capture new screenshot → verify state changed
- If verification fails, retry with backoff (max 3-5 attempts)
- Re-screenshot after keyboard/modal/scroll events before any subsequent coordinate prediction
- Manus spent **6 months and 5 complete architectural rewrites** on their harness — model stayed the same

## Key Finding 5: iOS-Specific Coordinate Challenges

- iOS uses **logical points, not pixels** (1 point = 3 pixels on Super Retina)
- Safe area insets: top 44-59pt (notch/Dynamic Island), bottom 34pt (home indicator)
- Keyboards overlay ~40% of visible area when active
- iPhone screenshots can differ from native panel resolution
- Coordinate conversion chain: model_coord → scale_to_screenshot → scale_to_device_resolution → divide_by_scale_factor → point_coordinate

## Our Three Grounding Modes

| Mode | Technique | Based On | Expected Improvement |
|------|-----------|----------|---------------------|
| `baseline` | Raw screenshot + coordinate guessing | Current state | — |
| `grid` | Screenshot + 10% grid lines overlay | AppAgent (Tencent) | ~20-30% fewer wrong taps |
| `zoomclick` | Rough guess → 2x zoom → refined prediction | ZoomClick (Princeton) | ~48% fewer wrong taps on small targets |

## References

- [OmniParser — Microsoft](https://microsoft.github.io/OmniParser/) | [Paper](https://arxiv.org/abs/2408.00203)
- [OmniParser V2](https://www.microsoft.com/en-us/research/articles/omniparser-v2-turning-any-llm-into-a-computer-use-agent/)
- [ZoomClick — Princeton](https://arxiv.org/abs/2512.05941) | [GitHub](https://github.com/Princeton-AI2-Lab/ZoomClick)
- [AppAgent — Tencent](https://github.com/TencentQQGYLab/AppAgent)
- [UI-TARS — ByteDance](https://github.com/bytedance/UI-TARS)
- [ClickAgent — Samsung](https://github.com/Samsung/ClickAgent)
- [ScreenSpot-Pro](https://arxiv.org/html/2504.07981v1)
- [Anthropic Computer Use Docs](https://docs.anthropic.com/en/docs/agents-and-tools/computer-use)
- [Anthropic Vision Docs](https://docs.claude.com/en/docs/build-with-claude/vision)
- [GUI-Actor — NeurIPS 2025](https://arxiv.org/abs/2501.12326)
- [OSWorld — NeurIPS 2024](https://www.emergentmind.com/topics/osworld-environment)
- [A3 Android Agent Arena](https://arxiv.org/html/2501.01149v2)
