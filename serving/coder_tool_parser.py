"""vLLM tool-call parser plugin for Qwen2.5-Coder-Instruct.

The Coder model usually answers tool requests with a fenced JSON block  ```json {"name": ..., "arguments": {...}} ```
instead of the Hermes  <tool_call>{...}</tool_call>  wrapper that vLLM's `hermes` parser expects. This parser
accepts both, so OpenAI-style `tool_calls` (and, through the gateway, Anthropic `tool_use` blocks) work.
Unit: --tool-parser-plugin /home/ubuntu/vllm/coder_tool_parser.py --tool-call-parser coder_json --enable-auto-tool-choice
"""
import json, re, uuid
try:  # vLLM >= 0.28
    from vllm.tool_parsers.abstract_tool_parser import ToolParser, ToolParserManager
    from vllm.entrypoints.openai.engine.protocol import DeltaMessage, ExtractedToolCallInformation, FunctionCall, ToolCall
    from vllm.entrypoints.openai.chat_completion.protocol import ChatCompletionRequest
except ImportError:  # older layouts
    from vllm.entrypoints.openai.tool_parsers.abstract_tool_parser import ToolParser, ToolParserManager
    from vllm.entrypoints.openai.protocol import (ChatCompletionRequest, DeltaMessage, ExtractedToolCallInformation,
                                                  FunctionCall, ToolCall)

FENCED = re.compile(r"```(?:json|xml)?\s*(\{.*?\})\s*```", re.S)
TAGGED = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.S)

def _candidates(text):
    for rx in (TAGGED, FENCED):
        for m in rx.finditer(text):
            try:
                obj = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            objs = obj if isinstance(obj, list) else [obj]
            for o in objs:
                if isinstance(o, dict) and "name" in o and isinstance(o.get("arguments", o.get("parameters", {})), dict):
                    yield o, m.span()

class CoderJsonToolParser(ToolParser):
    def __init__(self, tokenizer, *args, **kwargs):  # newer vLLM passes extra args
        super().__init__(tokenizer, *args, **kwargs)

    def extract_tool_calls(self, model_output: str, request: ChatCompletionRequest, *args, **kwargs) -> ExtractedToolCallInformation:
        calls, spans = [], []
        for obj, span in _candidates(model_output):
            args = obj.get("arguments", obj.get("parameters", {}))
            calls.append(ToolCall(id=f"call_{uuid.uuid4().hex[:24]}", type="function",
                                  function=FunctionCall(name=obj["name"], arguments=json.dumps(args, ensure_ascii=False))))
            spans.append(span)
        if not calls:
            return ExtractedToolCallInformation(tools_called=False, tool_calls=[], content=model_output)
        content = model_output
        for a, b in sorted(spans, reverse=True):
            content = content[:a] + content[b:]
        content = content.strip() or None
        return ExtractedToolCallInformation(tools_called=True, tool_calls=calls, content=content)

    def extract_tool_calls_streaming(self, previous_text, current_text, delta_text, previous_token_ids,
                                     current_token_ids, delta_token_ids, request, *args, **kwargs):
        # Streaming: hold the fenced/tagged block back until it is complete, then emit the tool call once.
        if _has_open_block(current_text):
            return None
        if _has_open_block(previous_text):  # block just closed in this delta
            for obj, _ in _candidates(current_text):
                args = obj.get("arguments", obj.get("parameters", {}))
                return DeltaMessage(tool_calls=[{"index": 0, "id": f"call_{uuid.uuid4().hex[:24]}", "type": "function",
                                                 "function": {"name": obj["name"], "arguments": json.dumps(args, ensure_ascii=False)}}])
            return DeltaMessage(content=delta_text)
        if "```" in delta_text or "<tool_call>" in delta_text:
            return None
        return DeltaMessage(content=delta_text)

def _has_open_block(text):
    return text.count("```") % 2 == 1 or ("<tool_call>" in text and "</tool_call>" not in text.split("<tool_call>")[-1])

# Eager registration: vLLM validates --tool-call-parser names against the eager registry at startup.
ToolParserManager.register_module(name="coder_json", module=CoderJsonToolParser)
