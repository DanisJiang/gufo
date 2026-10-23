#!/usr/bin/env python3
"""Opt-in real-server checks for configurable Flash-Next shared context.

Uses an already running server; never loads a second model or builds code.
Reports are synthetic test traffic, not captures of other clients' requests.
"""

import argparse
import json
from pathlib import Path
import threading
import time

from openai import DefaultHttpxClient, OpenAI

from metrics import Recorder
from openai_sdk import CheckResults, chat_result, check_batches, check_long_context


def pool_checks(client, base, report):
    def props():
        return client.get(base + '/props', cast_to=dict[str, object])

    def slots():
        return client.get(base + '/slots', cast_to=list[dict[str, object]])

    initial = props()
    assert initial['total_slots'] == 6, initial
    assert initial['context_pool_tokens'] == 786432, initial
    report['configuration'] = initial

    def cohort(budgets, pressure=False):
        stops = [threading.Event() for _ in budgets]
        first = [threading.Event() for _ in budgets]
        results = [{} for _ in budgets]
        streams = {}
        lock = threading.Lock()

        def worker(index):
            started = time.monotonic()
            try:
                with client.completions.create(
                    model='qwen3.8-flash-next',
                    prompt=f'Unique pool probe {index}/{started}: continue the numbers 1 2 3 4 5',
                    max_tokens=budgets[index], temperature=0, stream=True,
                    extra_body={'ignore_eos': True, 'cache_prompt': False},
                ) as stream:
                    with lock:
                        streams[index] = stream
                    for chunk in stream:
                        if stops[index].is_set():
                            break
                        text = ''.join(choice.text for choice in chunk.choices)
                        if text and not first[index].is_set():
                            results[index]['first_token_s'] = time.monotonic() - started
                            results[index]['piece'] = text
                            first[index].set()
            except Exception as error:
                if not stops[index].is_set():
                    results[index]['error'] = repr(error)
                    first[index].set()

        threads = [threading.Thread(target=worker, args=(i,), daemon=True)
                   for i in range(len(budgets))]
        try:
            active = len(budgets) - (1 if pressure else 0)
            for i in range(active):
                threads[i].start()
                time.sleep(.02)
            for i in range(active):
                assert first[i].wait(300), (i, results)
                assert 'error' not in results[i], results
            observed = slots()
            assert sum(bool(slot.get('is_processing')) for slot in observed) >= active, observed
            result = {'requests': results, 'active_slots': observed, 'before': props()}
            assert result['before']['context_pool_reserved_tokens'] <= 786432, result
            if pressure:
                threads[-1].start()
                time.sleep(3)
                assert not first[-1].is_set(), results
                result['while_waiting'] = props()
                stops[0].set()
                with lock:
                    stream = streams.get(0)
                if stream:
                    stream.close()
                assert first[-1].wait(120), results
                assert 'error' not in results[-1], results
                result['after_release'] = props()
                assert result['after_release']['context_pool_reserved_tokens'] <= 786432, result
            return result
        finally:
            for stop in stops:
                stop.set()
            with lock:
                opened = list(streams.values())
            for stream in opened:
                stream.close()
            for thread in threads:
                if thread.ident is not None:
                    thread.join(30)

    report['six_active'] = cohort([90000] * 6)
    print('PASS six active sessions', flush=True)
    report['capacity_wait_and_resume'] = cohort([150000] * 5 + [100000], True)
    print('PASS pool pressure waits with a spare session, then resumes', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--revision', required=True, help='Revision of the tested server binary')
    parser.add_argument('--stage', choices=('smoke', 'pool', 'cache', 'long'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    base = args.url.rstrip('/')
    recorder = Recorder(args.output.with_suffix('.requests.json'))
    report = {'revision': args.revision, 'stage': args.stage, 'checks': {}}
    checks = CheckResults(report, args.output, recorder)
    report['checks'] = checks
    transport = DefaultHttpxClient(trust_env=False, event_hooks={
        'request': [recorder.request_hook], 'response': [recorder.response_hook]})
    try:
        with OpenAI(base_url=base + '/v1', api_key='local-test', max_retries=0,
                    timeout=900, http_client=transport) as client:
            if args.stage == 'smoke':
                body = dict(model='qwen3.8-flash-next', temperature=0,
                            max_completion_tokens=32, reasoning_effort='none',
                            messages=[{'role': 'user', 'content': 'Reply with only the word LANTERN.'}])
                cold = chat_result(client, body)
                checks['cold'] = cold
                warm = chat_result(client, body, True)
                checks['warm'] = warm
                assert cold['text'].strip() == 'LANTERN', cold
                assert warm['text'] == cold['text'], (cold, warm)
                assert warm['usage']['cached_tokens'] > 0, warm
            elif args.stage == 'pool':
                # Cancelled stress streams do not have final usage trailers;
                # the official recorder is used for completed correctness cases.
                with OpenAI(base_url=base + '/v1', api_key='local-test', max_retries=0,
                            timeout=900, http_client=DefaultHttpxClient(trust_env=False)) as raw:
                    pool_checks(raw, base, checks)
            elif args.stage == 'cache':
                check_batches(client, 'qwen3.8-flash-next', checks, 6, speculative='mtp')
            else:
                check_long_context(client, 'qwen3.8-flash-next', checks, 262144)
        report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'failed'
        report['error'] = repr(error)
        raise
    finally:
        checks.save()
    print(f'PASS {args.stage}', flush=True)


if __name__ == '__main__':
    main()
