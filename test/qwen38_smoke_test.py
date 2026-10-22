"""Offline fixtures only: importing the tool must not contact a server."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1] / "devbox/apps/llama-server/smoke.py"


def response(content="正常な日本語の応答です。", finish="stop", reasoning=None):
    message = {"role": "assistant", "content": content}
    if reasoning is not None:
        message["reasoning_content"] = reasoning
    return {"choices": [{"message": message, "finish_reason": finish}]}


def tool_response():
    result = response(None, "tool_calls")
    result["choices"][0]["message"]["tool_calls"] = [{
        "id": "call_fixture", "type": "function", "function": {
            "name": "get_temperature", "arguments": '{"city":"東京"}'}}]
    return result


class SmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("smoke", TOOL)
        cls.smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.smoke)

    def test_requests_are_bounded_and_explicit(self):
        for case in self.smoke.CASES:
            req = self.smoke.request(case)
            self.assertEqual(req["model"], "qwen3.8-flash-next")
            self.assertLessEqual(req["max_tokens"], 256)
            self.assertFalse(req["stream"])
            self.assertEqual(req["temperature"], 0)
            self.assertEqual(req["chat_template_kwargs"]["enable_thinking"], case == "thinking-on")
        req = self.smoke.request("tool")
        self.assertEqual(req["tool_choice"]["function"]["name"], "get_temperature")
        self.assertEqual(req["tools"][0]["function"]["parameters"]["required"], ["city"])

    def test_japanese_and_thinking(self):
        self.smoke.validate("japanese", response())
        self.smoke.validate("thinking-off", response("323", reasoning=""))
        self.smoke.validate("thinking-on", response("323です。", reasoning="確認します。"))
        self.smoke.validate("tool", tool_response())

    def test_reject_incomplete_or_missing_japanese(self):
        for fixture in (response(finish="length"), response(""), response("English only"),
                        {"error": {"message": "bad request"}}, {"choices": []},
                        response(content=None), response(finish="tool_calls")):
            with self.subTest(fixture=fixture), self.assertRaises(ValueError):
                self.smoke.validate("japanese", fixture)

    def test_arithmetic_checks_answer_not_language(self):
        for text in ("323", "323です。", "答えは **323** です。", "17 × 19 = 323", "17×19は323です。"):
            for case in ("thinking-off", "thinking-on"):
                with self.subTest(text=text, case=case):
                    self.smoke.validate(case, response(text, reasoning="計算を確認しました。" if case == "thinking-on" else None))
        for text in ("324", "正常な日本語です。", "", "323ではなく324", "323ではありません。", "1323", "3230", "323.5", "-323", "<think>323</think>323"):
            for case in ("thinking-off", "thinking-on"):
                with self.subTest(text=text, case=case), self.assertRaises(ValueError):
                    self.smoke.validate(case, response(text, reasoning="確認。" if case == "thinking-on" else None))
        for case in ("thinking-off", "thinking-on"):
            with self.assertRaises(ValueError):
                self.smoke.validate(case, response("323", finish="length", reasoning="確認。"))

    def test_thinking_paths_are_distinct(self):
        with self.assertRaises(ValueError):
            self.smoke.validate("thinking-on", response("323"))
        with self.assertRaises(ValueError):
            self.smoke.validate("thinking-off", response("323", reasoning="考えます。"))
        with self.assertRaises(ValueError):
            self.smoke.validate("thinking-off", response("<think>思考</think>回答です。"))
        for invalid in (42, False, [], {}):
            for case in ("thinking-off", "thinking-on"):
                with self.subTest(case=case, invalid=invalid), self.assertRaises(ValueError):
                    self.smoke.validate(case, response("323", reasoning=invalid))

    def test_tools_require_json_schema_and_finish_reason(self):
        for arguments in ('not json', '[]', '{}', '{"city":42}', '{"city":"大阪"}',
                          '{"city":"東京","extra":true}'):
            fixture = tool_response()
            fixture["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = arguments
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                self.smoke.validate("tool", fixture)
        for mutate in (
            lambda r: r["choices"][0].update(finish_reason="stop"),
            lambda r: r["choices"][0]["message"].update(tool_calls=[]),
            lambda r: r["choices"][0]["message"]["tool_calls"][0]["function"].update(name="wrong"),
            lambda r: r["choices"][0]["message"]["tool_calls"][0].update(id=""),
        ):
            fixture = copy.deepcopy(tool_response())
            mutate(fixture)
            with self.assertRaises(ValueError):
                self.smoke.validate("tool", fixture)

    def test_cli_is_offline_and_reports_failure_without_response_text(self):
        generated = subprocess.run([sys.executable, str(TOOL), "request", "tool"],
                                   capture_output=True, text=True, check=True)
        self.assertIn("tools", json.loads(generated.stdout))
        for raw in ('secret-invalid-json', json.dumps(response(finish="length")), 'null', '[]',
                    '{"choices":[null]}'):
            result = subprocess.run([sys.executable, str(TOOL), "validate", "japanese"],
                                    input=raw, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("secret-invalid-json", result.stderr)


if __name__ == "__main__":
    unittest.main()
