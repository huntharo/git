"""Exercise the packaged config chain without modifying host/user config."""
import os
from pathlib import Path
import subprocess
import tempfile


def verify_configuration(git, config, environment):
    git, config = Path(git).resolve(), Path(config).resolve()
    env = {k: v for k, v in environment.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_SYSTEM=str(config), GIT_CONFIG_GLOBAL=os.devnull)

    def command(*args, cwd=None, extra=None, missing=False):
        result = subprocess.run([str(git), *args], cwd=cwd,
                                env=dict(env, **(extra or {})),
                                capture_output=True, text=True, check=False)
        if missing:
            if result.returncode != 1 or result.stdout:
                raise ValueError(f'Expected no value for {args[-1]}: {result}')
            return None
        result.check_returncode()
        return result.stdout.strip()

    def expect(expected, *args, **kwargs):
        actual = command(*args, **kwargs)
        if actual != expected:
            raise ValueError(f'Expected {expected!r} from git {args!r}, got {actual!r}')

    expect('/etc/gitconfig', 'config', '--system', '--no-includes', '--get-all', 'include.path')
    command('config', '--system', '--no-includes', '--get',
            'checkout.reflink', missing=True)
    expect('true', 'config', '--system', '--no-includes', '--bool', '--get',
           'credential.https://dev.azure.com.useHttpPath')

    with tempfile.TemporaryDirectory(prefix='pwrgit-config-') as tmp:
        root = Path(tmp)
        system, global_file = root / 'system config', root / 'global config'
        included, overlay = root / 'included global config', root / 'runtime config'
        system.write_text('[pwrgitRuntimeTest]\n\tsystem = visible\n\tpriority = system\n'
                          '[checkout]\n\treflink = true\n')
        included.write_text('[pwrgitRuntimeTest]\n\tglobal = visible\n\tpriority = global\n')
        global_file.touch()
        overlay.write_bytes(config.read_bytes())
        # Redirect only the fixture's include: never write the real /etc/gitconfig.
        command('config', '--file', overlay, '--replace-all', 'include.path', system)
        command('config', '--file', global_file, 'include.path', included)
        overrides = dict(GIT_CONFIG_SYSTEM=str(overlay), GIT_CONFIG_GLOBAL=str(global_file))
        repo = root / 'repository'
        command('init', '-q', repo, extra=overrides)
        command('config', 'pwrgitRuntimeTest.repository', 'visible', cwd=repo, extra=overrides)
        command('config', 'pwrgitRuntimeTest.priority', 'repository', cwd=repo, extra=overrides)
        for scope in ('system', 'global', 'repository'):
            expect('visible', 'config', '--get', 'pwrgitRuntimeTest.' + scope, cwd=repo, extra=overrides)
        expect('system\nglobal\nrepository', 'config', '--get-all', 'pwrgitRuntimeTest.priority',
               cwd=repo, extra=overrides)
        expect('command', '-c', 'pwrgitRuntimeTest.priority=command', 'config', '--get',
               'pwrgitRuntimeTest.priority', cwd=repo, extra=overrides)
        expect('true', 'config', '--bool', '--get', 'checkout.reflink', cwd=repo, extra=overrides)
        command('config', '--file', global_file, 'checkout.reflink', 'false')
        expect('false', 'config', '--bool', '--get', 'checkout.reflink', cwd=repo, extra=overrides)
        expect('true', '-c', 'checkout.reflink=true', 'config', '--bool', '--get',
               'checkout.reflink', cwd=repo, extra=overrides)
        command('config', '--get', 'pwrgitRuntimeTest.system', cwd=repo,
                extra=dict(overrides, GIT_CONFIG_NOSYSTEM='1'), missing=True)
        alternate = root / 'explicit system config'
        alternate.write_text('[pwrgitRuntimeTest]\n\tsystem = explicit\n')
        expect('explicit', 'config', '--get', 'pwrgitRuntimeTest.system', cwd=repo,
               extra=dict(overrides, GIT_CONFIG_SYSTEM=str(alternate)))
    return dict(system_include='/etc/gitconfig', azure_use_http_path=True,
                runtime_reflink_default=False, system_global_repository_visible=True,
                includes_and_precedence=True, explicit_system_override=True,
                nosystem_honored=True)
