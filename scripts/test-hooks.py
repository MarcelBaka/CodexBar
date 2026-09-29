#!/usr/bin/env python3
import json, os, pathlib, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parent.parent
manager = root / 'scripts/manage-hooks.py'
app = root / 'build/Codex Touch Bar.app'
with tempfile.TemporaryDirectory(prefix='codex-touchbar-hook-test-') as temp:
    base = pathlib.Path(temp)
    home = base / 'codex home'; home.mkdir()
    support = base / 'support with spaces'
    original = {'description': 'keep me', 'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': '/usr/bin/true', 'timeout': 1}]}]}}
    (home / 'hooks.json').write_text(json.dumps(original))
    def manage(action, interactive=False):
        subprocess.run(['/usr/bin/python3', str(manager), action, '--app', str(app), '--codex-home', str(home), '--support-dir', str(support)] + (['--approval-ui'] if interactive else []), check=True, capture_output=True)
    manage('install'); manage('install')
    installed = json.loads((home / 'hooks.json').read_text())
    assert installed['description'] == 'keep me'
    assert len(installed['hooks']['Stop']) == 2, 'idempotent merge'
    assert len(installed['hooks']['PermissionRequest']) == 1
    assert list(home.glob('hooks.json.backup-*')), 'backup present'
    telemetry = base / 'telemetry'
    env = dict(os.environ, CODEX_TOUCH_BAR_HOOK_DIR=str(telemetry))
    payload = {'hook_event_name': 'PermissionRequest', 'session_id': 'safe-thread', 'tool_input': {'command': 'DO NOT STORE'}, 'cwd': '/tmp/project'}
    result = subprocess.run([str(support / 'CodexTouchBarHook')], input=json.dumps(payload), text=True, capture_output=True, check=True, env=env)
    assert json.loads(result.stdout) == {}, 'never returns approval decision'
    assert 'DO NOT STORE' not in (telemetry / 'safe-thread.jsonl').read_text()
    invalid = subprocess.run([str(support / 'CodexTouchBarHook')], input='invalid json', text=True, capture_output=True, check=True, env=env)
    assert json.loads(invalid.stdout) == {}, 'invalid input cannot block Codex'
    process = subprocess.Popen([str(support / 'CodexTouchBarHook')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    encoded = json.dumps(payload).encode()
    process.stdin.write(encoded[:20]); process.stdin.flush(); time.sleep(0.03)
    process.stdin.write(encoded[20:]); process.stdin.close()
    assert process.wait(timeout=5) == 0
    assert json.loads(process.stdout.read()) == {}, 'fragmented stdin supported'
    manage('install', interactive=True)
    interactive_config = json.loads((home / 'hooks.json').read_text())['hooks']['PermissionRequest']
    assert len(interactive_config) == 1
    assert interactive_config[0]['hooks'][0]['command'].endswith(' --approval-ui')
    assert interactive_config[0]['hooks'][0]['timeout'] == 125
    # Exercise the actual documented hook approval response, with explicit request IDs.
    approvals = base / 'approvals'; approvals.mkdir(mode=0o700)
    # Swift Codable Date uses seconds since 2001-01-01.
    def heartbeat():
        (approvals / 'active.json').write_text(json.dumps(time.time() - 978307200))
        (approvals / 'active.json').chmod(0o600)
    for action in ['allow', 'deny', 'defer']:
        heartbeat()
        active_env = dict(env, CODEX_TOUCH_BAR_APPROVAL_DIR=str(approvals))
        approval_payload = dict(payload, tool_name='Bash', turn_id='test-turn')
        process = subprocess.Popen([str(support / 'CodexTouchBarHook'), '--approval-ui'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=active_env)
        process.stdin.write(json.dumps(approval_payload).encode()); process.stdin.close()
        deadline = time.time() + 5
        request_files = []
        while time.time() < deadline:
            request_files = list(approvals.glob('*.request.json'))
            if request_files: break
            time.sleep(0.02)
        assert request_files, 'live request created'
        request = json.loads(request_files[0].read_text())
        assert 'DO NOT STORE' in request['inputJSON'], 'review retains full proposed tool input temporarily'
        reply = approvals / (request['id'] + '.reply.json')
        reply.write_text(json.dumps({'id': 'wrong-request', 'decision': 'allow'})); reply.chmod(0o600)
        time.sleep(0.1)
        assert process.poll() is None, 'unrelated response must not approve'
        reply.write_text(json.dumps({'id': request['id'], 'decision': action}))
        assert process.wait(timeout=5) == 0
        response = json.loads(process.stdout.read())
        if action == 'defer': assert response == {}
        else:
            assert response['hookSpecificOutput']['hookEventName'] == 'PermissionRequest'
            assert response['hookSpecificOutput']['decision']['behavior'] == action
        assert not list(approvals.glob('*.request.json')), 'request data removed after resolution'
    manage('uninstall')
    assert json.loads((home / 'hooks.json').read_text()) == original, 'preserve unrelated config'
print('PASS request-bound allow/deny/defer responses, rejection of mismatched IDs, private temporary review data')
print('PASS hook installer merge, backup, idempotence, spaces, helper privacy, fail-open observer, uninstall')
