#!/usr/bin/env python3
"""Generate synthetic smoke requests and validate saved replies; never uses the network."""
import argparse
import json
import re
import sys

CASES = ("japanese", "thinking-off", "thinking-on", "tool")
JAPANESE = re.compile(r"[ぁ-んァ-ヶ一-龯]")
# Deliberately bounded answer grammar, not a substring search for any number.
ARITHMETIC_ANSWER = re.compile(
    r"(?:答えは\s*)?(?:17\s*[×*]\s*19\s*[=＝は]\s*)?"
    r"(?:\*\*323\*\*|323)\s*(?:です)?[。.!！]?"
)


def request(case):
    if case not in CASES:
        raise ValueError("unknown case")
    prompts = {
        "japanese": "日本語で、空が青く見える理由を一文で説明してください。",
        "thinking-off": "17×19はいくつですか。日本語で短く答えてください。",
        "thinking-on": "17×19を段階的に確認してから、日本語で短く答えてください。",
        "tool": "東京の気温をget_temperatureツールで調べてください。推測で答えないでください。",
    }
    result = {
        "model": "qwen3.8-flash-next", "messages": [{"role": "user", "content": prompts[case]}],
        "temperature": 0, "seed": 42, "max_tokens": 256, "stream": False,
        "chat_template_kwargs": {"enable_thinking": case == "thinking-on"},
    }
    if case == "thinking-on":
        result["reasoning_effort"] = "low"
    if case == "tool":
        result["tools"] = [{"type": "function", "function": {
            "name": "get_temperature", "description": "指定都市の気温を調べる（検証用、実行しない）。",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                           "required": ["city"], "additionalProperties": False}}}]
        result["tool_choice"] = {"type": "function", "function": {"name": "get_temperature"}}
    return result


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(case, reply):
    require(case in CASES, "unknown case")
    require(isinstance(reply, dict) and "error" not in reply, "expected a successful JSON object")
    choices = reply.get("choices")
    require(isinstance(choices, list) and len(choices) == 1, "expected exactly one choice")
    choice = choices[0]
    require(isinstance(choice, dict), "expected a choice object")
    message = choice.get("message")
    require(isinstance(message, dict) and message.get("role") == "assistant", "expected assistant message")
    if case == "tool":
        require(choice.get("finish_reason") == "tool_calls", "expected finish_reason=tool_calls")
        calls = message.get("tool_calls")
        require(isinstance(calls, list) and len(calls) == 1, "expected exactly one tool call")
        call = calls[0]
        require(isinstance(call, dict) and call.get("type") == "function", "expected function tool call")
        require(isinstance(call.get("id"), str) and bool(call["id"].strip()), "expected tool call id")
        function = call.get("function")
        require(isinstance(function, dict) and function.get("name") == "get_temperature", "wrong tool name")
        arguments = function.get("arguments")
        require(isinstance(arguments, str), "expected JSON arguments string")
        try:
            arguments = json.loads(arguments)
        except (ValueError, TypeError):
            raise ValueError("invalid tool arguments JSON") from None
        require(arguments == {"city": "東京"}, "tool arguments do not match the requested city/schema")
    else:
        require(choice.get("finish_reason") == "stop", "expected finish_reason=stop (length is not a pass)")
        content = message.get("content")
        require(isinstance(content, str) and bool(content.strip()), "expected nonempty content")
        if case == "japanese":
            require(JAPANESE.search(content) is not None, "expected Japanese content")
        else:
            require(ARITHMETIC_ANSWER.fullmatch(content.strip()) is not None, "expected the answer 323")
        require("<think>" not in content and "</think>" not in content, "reasoning leaked into content")
        require(not message.get("tool_calls"), "unexpected tool calls")
        reasoning = message.get("reasoning_content")
        if case == "thinking-on":
            require(isinstance(reasoning, str) and bool(reasoning.strip()), "thinking-on path not observed")
        elif case == "thinking-off":
            require(reasoning is None or reasoning == "", "unexpected thinking-off reasoning")
    # Do not echo model text or tool arguments into logs.
    return {"case": case, "passed": True, "finish_reason": choice["finish_reason"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("request", "validate"))
    parser.add_argument("case", choices=CASES)
    args = parser.parse_args()
    try:
        result = request(args.case) if args.action == "request" else validate(args.case, json.load(sys.stdin))
    except (ValueError, TypeError, RecursionError):
        # Fixed diagnostic: malformed responses can contain secrets or escape codes.
        print("smoke: validation failed; inspect the saved response privately", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
