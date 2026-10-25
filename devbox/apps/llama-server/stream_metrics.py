#!/usr/bin/env python3
"""Bounded, body-free OpenAI SSE arrival metrics; offline CLI only."""
import argparse
import base64
import binascii
import json
import math
import statistics
import sys


class MetricError(ValueError):
    """Messages must be constant codes, never transport/model text."""


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


class Collector:
    """Adapter calls headers/feed immediately after receipt, using monotonic_ns.

    start_ns is captured immediately before send, not after headers. No raw text
    is retained after event parsing. This class never sends or executes anything.
    """

    def __init__(self, start_ns, timeout_seconds=180, max_output_tokens=256,
                 max_bytes=4 * 1024 * 1024):
        if type(start_ns) is not int or start_ns < 0:
            raise MetricError('invalid_clock')
        if not number(timeout_seconds) or timeout_seconds == 0:
            raise MetricError('invalid_budget')
        if type(max_output_tokens) is not int or max_output_tokens <= 0 or type(max_bytes) is not int or max_bytes <= 0:
            raise MetricError('invalid_budget')
        self.start = self.last = start_ns
        self.timeout = timeout_seconds
        self.max_tokens, self.max_bytes = max_output_tokens, max_bytes
        self.size = 0
        self.buffer = b''
        self.data = []
        self.event_type = ''
        self.first = dict.fromkeys(('reasoning', 'content', 'tool', 'any'))
        self.last_delta = None
        self.header = self.final = self.done = None
        self.finish_reason = None
        self.usage = self.timings = None
        self.closed = False

    def _clock(self, at_ns):
        if self.closed or type(at_ns) is not int or at_ns < self.last:
            raise MetricError('invalid_clock_or_closed')
        self.last = at_ns
        elapsed = (at_ns - self.start) / 1e9
        if elapsed > self.timeout:
            raise MetricError('timeout')
        return elapsed

    def headers(self, at_ns, status):
        elapsed = self._clock(at_ns)
        if type(status) is not int or status != 200:
            raise MetricError('http_error')
        if self.header is not None:
            raise MetricError('duplicate_headers')
        self.header = elapsed

    def feed(self, at_ns, chunk):
        elapsed = self._clock(at_ns)
        if self.header is None or not isinstance(chunk, bytes):
            raise MetricError('invalid_transport')
        self.size += len(chunk)
        if self.size > self.max_bytes:
            raise MetricError('response_byte_budget')
        self.buffer += chunk
        # SSE line endings: CRLF, LF, or CR. Delay trailing CR until next read.
        while self.buffer:
            positions = [p for p in (self.buffer.find(b'\n'), self.buffer.find(b'\r')) if p >= 0]
            if not positions:
                break
            pos = min(positions)
            if self.buffer[pos:] == b'\r':
                break
            width = 2 if self.buffer[pos:pos + 2] == b'\r\n' else 1
            raw, self.buffer = self.buffer[:pos], self.buffer[pos + width:]
            try:
                line = raw.decode('utf-8')
            except UnicodeError:
                raise MetricError('invalid_utf8') from None
            self._line(line, elapsed)

    def _line(self, line, elapsed):
        if not line:
            if self.event_type == 'error':
                raise MetricError('server_error')
            if self.data:
                self._event('\n'.join(self.data), elapsed)
            self.data, self.event_type = [], ''
        elif not line.startswith(':'):
            field, sep, value = line.partition(':')
            if sep and value.startswith(' '):
                value = value[1:]
            if field == 'data':
                self.data.append(value)
            elif field == 'event':
                self.event_type = value

    def _event(self, text, elapsed):
        if self.done is not None:
            raise MetricError('event_after_done')
        if text == '[DONE]':
            self.done = elapsed
            return
        try:
            obj = json.loads(text)
        except (ValueError, RecursionError):
            raise MetricError('invalid_json') from None
        if not isinstance(obj, dict):
            raise MetricError('invalid_schema')
        if 'error' in obj:
            raise MetricError('server_error')
        choices = obj.get('choices')
        if not isinstance(choices, list) or len(choices) > 1:
            raise MetricError('invalid_choices')
        if choices:
            ch = choices[0]
            if not isinstance(ch, dict) or type(ch.get('index')) is not int or ch['index'] != 0:
                raise MetricError('unsupported_choice')
            delta = ch.get('delta')
            if not isinstance(delta, dict):
                raise MetricError('invalid_delta')
            kinds = []
            for field, kind in [('reasoning_content', 'reasoning'), ('reasoning', 'reasoning'), ('content', 'content')]:
                value = delta.get(field)
                if value is not None and not isinstance(value, str):
                    raise MetricError('invalid_delta')
                if value:
                    kinds.append(kind)
            calls = delta.get('tool_calls', [])
            if not isinstance(calls, list):
                raise MetricError('invalid_tool_delta')
            for call in calls:
                if not isinstance(call, dict) or not isinstance(call.get('function', {}), dict):
                    raise MetricError('invalid_tool_delta')
                for field in ('name', 'arguments'):
                    value = call.get('function', {}).get(field)
                    if value is not None and not isinstance(value, str):
                        raise MetricError('invalid_tool_delta')
                    if value:
                        kinds.append('tool')
            if kinds:
                if self.final is not None:
                    raise MetricError('delta_after_final')
                for kind in kinds + ['any']:
                    if self.first[kind] is None:
                        self.first[kind] = elapsed
                self.last_delta = elapsed
            reason = ch.get('finish_reason')
            if reason is not None:
                if reason not in ('stop', 'tool_calls') or self.final is not None:
                    raise MetricError('invalid_finish_reason')
                self.finish_reason, self.final = reason, elapsed
        if obj.get('usage') is not None:
            value = obj['usage']
            if not isinstance(value, dict):
                raise MetricError('invalid_usage')
            usage = {}
            for key in ('prompt_tokens', 'completion_tokens', 'total_tokens'):
                if key in value:
                    if type(value[key]) is not int or value[key] < 0:
                        raise MetricError('invalid_usage')
                    usage[key] = value[key]
            if usage.get('completion_tokens', 0) > self.max_tokens:
                raise MetricError('generation_budget')
            self.usage = usage
        if obj.get('timings') is not None:
            value = obj['timings']
            if not isinstance(value, dict):
                raise MetricError('invalid_timings')
            timings = {}
            for key in ('prompt_n', 'prompt_ms', 'predicted_n', 'predicted_ms', 'cache_n', 'draft_n', 'draft_n_accepted'):
                if key in value:
                    if not number(value[key]):
                        raise MetricError('invalid_timings')
                    timings[key] = value[key]
            self.timings = timings

    def finish(self, at_ns):
        wall = self._clock(at_ns)
        # A final CR is a valid line terminator, not a fabricated SSE delimiter.
        if self.buffer.endswith(b'\r'):
            self.feed(at_ns, b'\n')
        if self.buffer or self.data or self.final is None or self.done is None:
            raise MetricError('incomplete_stream')
        self.closed = True
        tokens = (self.usage or {}).get('completion_tokens')
        span = None if self.last_delta is None else self.last_delta - self.first['any']
        rate = tokens / span if tokens is not None and span and span > 0 else None
        return {'schema_version': 1, 'ttft_seconds': self.first.copy(),
                'header_seconds': self.header, 'final_seconds': self.final,
                'done_seconds': self.done, 'wall_seconds': wall,
                'finish_reason': self.finish_reason, 'usage': self.usage,
                'server_timings': self.timings,
                'client_decode_tokens_per_second': rate}


def summarize(rows):
    if not rows:
        raise MetricError('empty_summary')
    result = {}
    for label, getter in [
        *[(kind + '_ttft_seconds', lambda r, k=kind: r['ttft_seconds'][k])
          for kind in ('reasoning', 'content', 'tool', 'any')],
        ('wall_seconds', lambda r: r['wall_seconds']),
        ('client_decode_tokens_per_second', lambda r: r['client_decode_tokens_per_second'])]:
        values = []
        for row in rows:
            if row.get('schema_version') != 1:
                raise MetricError('invalid_summary_schema')
            value = getter(row)
            if value is not None:
                if not number(value):
                    raise MetricError('invalid_summary_number')
                values.append(value)
        result[label] = {'n': len(values), 'missing': len(rows) - len(values),
                         'median': statistics.median(values) if values else None,
                         'min': min(values) if values else None,
                         'max': max(values) if values else None}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['replay', 'summary'])
    parser.add_argument('--timeout-seconds', type=float, default=180)
    parser.add_argument('--max-output-tokens', type=int, default=256)
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024:
            raise MetricError('fixture_byte_budget')
        doc = json.loads(raw)
        if args.mode == 'summary':
            result = summarize(doc)
        else:
            if doc['synthetic'] is not True:
                raise MetricError('synthetic_fixture_required')
            c = Collector(doc['start_ns'], args.timeout_seconds, args.max_output_tokens)
            c.headers(doc['headers_ns'], doc['status'])
            for chunk in doc['chunks']:
                c.feed(chunk['at_ns'], base64.b64decode(chunk['base64'], validate=True))
            result = c.finish(doc['end_ns'])
        print(json.dumps(result, allow_nan=False))
        return 0
    except MetricError as exc:
        print('measurement_error: ' + str(exc), file=sys.stderr)
    except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError, binascii.Error):
        print('measurement_error: invalid_fixture_or_summary', file=sys.stderr)
    except KeyboardInterrupt:
        print('measurement_error: cancelled', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
