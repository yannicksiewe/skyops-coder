"""Unit tests for the pure parts of serving/coder_tool_parser.py (vLLM is stubbed; no GPU needed)."""
import importlib.util, os, sys, types

def _load():
    # stub the vLLM modules the plugin imports so the parsing helpers can be tested anywhere
    stub_abs = types.ModuleType("vllm.tool_parsers.abstract_tool_parser")
    class ToolParser:  # minimal base
        def __init__(self, tokenizer, *a, **k): pass
    class ToolParserManager:
        tool_parsers = {}
        @classmethod
        def register_module(cls, name=None, force=True, module=None): cls.tool_parsers[name] = module; return module
    stub_abs.ToolParser, stub_abs.ToolParserManager = ToolParser, ToolParserManager
    proto = types.ModuleType("vllm.entrypoints.openai.engine.protocol")
    class _D(dict):
        def __init__(self, **k): super().__init__(**k); self.__dict__ = self
    proto.DeltaMessage = proto.ExtractedToolCallInformation = proto.FunctionCall = proto.ToolCall = _D
    chat = types.ModuleType("vllm.entrypoints.openai.chat_completion.protocol"); chat.ChatCompletionRequest = object
    for name, mod in {"vllm": types.ModuleType("vllm"), "vllm.tool_parsers": types.ModuleType("vllm.tool_parsers"),
                      "vllm.tool_parsers.abstract_tool_parser": stub_abs, "vllm.entrypoints": types.ModuleType("vllm.entrypoints"),
                      "vllm.entrypoints.openai": types.ModuleType("vllm.entrypoints.openai"), "vllm.entrypoints.openai.engine": types.ModuleType("x"),
                      "vllm.entrypoints.openai.engine.protocol": proto, "vllm.entrypoints.openai.chat_completion": types.ModuleType("y"),
                      "vllm.entrypoints.openai.chat_completion.protocol": chat}.items():
        sys.modules.setdefault(name, mod)
    path = os.path.join(os.path.dirname(__file__), "..", "coder_tool_parser.py")
    spec = importlib.util.spec_from_file_location("coder_tool_parser", path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m

M = _load()

def test_fenced_json_call_is_detected():
    calls = list(M._candidates('Sure.\n```json\n{"name": "Read", "arguments": {"file_path": "/x"}}\n```'))
    assert len(calls) == 1 and calls[0][0]["name"] == "Read" and calls[0][0]["arguments"] == {"file_path": "/x"}

def test_hermes_tag_and_parameters_alias():
    calls = list(M._candidates('<tool_call>{"name": "Bash", "parameters": {"command": "ls"}}</tool_call>'))
    assert calls[0][0]["name"] == "Bash"

def test_code_answers_are_not_tool_calls():
    assert list(M._candidates('```python\nprint("hi")\n```')) == []
    assert list(M._candidates('```json\n{"status": "ok", "items": []}\n```')) == []   # JSON without a tool name

def test_extract_removes_call_from_content():
    p = M.CoderJsonToolParser(tokenizer=None)
    r = p.extract_tool_calls('Let me look.\n```json\n{"name": "Read", "arguments": {"file_path": "/x"}}\n```', None)
    assert r["tools_called"] and r["content"] == "Let me look." and r["tool_calls"][0]["function"]["name"] == "Read"

def test_open_block_detection():
    assert M._has_open_block("text ```json\n{") and not M._has_open_block("done ```json\n{}\n```")
    assert M._has_open_block("<tool_call>{") and not M._has_open_block("<tool_call>{}</tool_call>")
