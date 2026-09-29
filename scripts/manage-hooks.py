#!/usr/bin/env python3
"""Merge only this app's observer hooks; never change Codex's hook trust database."""
import argparse, json, os, pathlib, shlex, shutil, tempfile, time

EVENTS = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop', 'Interrupt']
MARKER = 'Codex Touch Bar observer'
APPROVAL_MARKER = 'Codex Touch Bar approval review'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'uninstall'])
    parser.add_argument('--approval-ui', action='store_true', help='Opt in to request-specific approval review in the running app')
    parser.add_argument('--app', default=str(pathlib.Path(__file__).resolve().parent.parent / 'build' / 'Codex Touch Bar.app'))
    parser.add_argument('--codex-home', default=os.environ.get('CODEX_HOME', str(pathlib.Path.home() / '.codex')))
    parser.add_argument('--support-dir', default=str(pathlib.Path.home() / 'Library/Application Support/Codex Touch Bar'))
    args = parser.parse_args()
    root = pathlib.Path(args.codex_home).expanduser().resolve()
    support = pathlib.Path(args.support_dir).expanduser().resolve()
    config = root / 'hooks.json'
    if config.is_symlink():
        raise SystemExit('Refusing to replace a symlink hooks.json. Merge the observer configuration manually.')
    content = json.loads(config.read_text()) if config.exists() else {}
    if not isinstance(content, dict) or not isinstance(content.get('hooks', {}), dict):
        raise SystemExit('Unrecognized hooks.json. Existing file left unchanged.')
    hooks = content.setdefault('hooks', {})
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise SystemExit('Unrecognized hooks.json event shape. Existing file left unchanged.')
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('hooks'), list):
                raise SystemExit('Unrecognized hook group. Existing file left unchanged.')
            remaining = [h for h in group['hooks'] if not (isinstance(h, dict) and h.get('statusMessage') in (MARKER, APPROVAL_MARKER))]
            if remaining:
                kept.append(dict(group, hooks=remaining))
        if kept: hooks[event] = kept
        else: hooks.pop(event)
    if args.action == 'install':
        source = pathlib.Path(args.app) / 'Contents/MacOS/CodexTouchBarHook'
        if not source.is_file(): raise SystemExit('Build the .app first; hook helper not found: ' + str(source))
        support.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination = support / 'CodexTouchBarHook'
        if destination.is_symlink(): raise SystemExit('Refusing to replace symlink helper.')
        temp = support / ('CodexTouchBarHook.install-' + str(os.getpid()))
        shutil.copy2(source, temp); temp.chmod(0o700); os.replace(temp, destination)
        command = shlex.quote(str(destination))
        for event in EVENTS:
            interactive = args.approval_ui and event == 'PermissionRequest'
            hooks.setdefault(event, []).append({'hooks': [{'type': 'command', 'command': command + (' --approval-ui' if interactive else ''), 'timeout': 125 if interactive else 3, 'statusMessage': APPROVAL_MARKER if interactive else MARKER}]})
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if config.exists(): shutil.copy2(config, str(config) + '.backup-' + str(time.time_ns()))
    fd, temporary = tempfile.mkstemp(prefix='.codex-touchbar-hooks-', dir=root)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(content, stream, indent=2); stream.write('\n')
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    print('Observer hooks ' + ('installed. Restart Codex, run /hooks, and review/trust these hooks.' if args.action == 'install' else 'removed. Restart Codex.'))
    print('Existing unrelated hooks and Codex settings were preserved.')

if __name__ == '__main__': main()
