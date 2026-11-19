#!/usr/bin/env python3
"""Publish the complete prepared release, or resume a verified draft."""
import argparse
import json
import os
from pathlib import Path

from runtime import run, sha256


def publish_release(repository, tag, directory):
    route = f'repos/{repository}/releases'
    expected = {p.name: 'sha256:' + sha256(p) for p in sorted(directory.iterdir())}

    def matching_draft():
        pages = json.loads(run(['gh', 'api', '--paginate', '--slurp', route + '?per_page=100']))
        matches = [entry for page in pages for entry in page if entry['tag_name'] == tag]
        if not matches:
            return None
        if len(matches) != 1 or matches[0]['draft'] is not True:
            raise ValueError(f'Expected at most one draft and no published release for {tag}')
        release_id = matches[0]['id']
        if type(release_id) is not int or release_id <= 0:
            raise ValueError(f'Invalid draft release ID for {tag}')
        return release_id

    release_id = matching_draft()
    if release_id is None:
        run(['gh', 'release', 'create', tag, '--repo', repository, '--verify-tag',
             '--draft', '--prerelease', '--title', f'Git {tag.removeprefix("v")}',
             '--notes-file', directory / 'RELEASE-NOTES.txt',
             *(directory / name for name in expected)])
        release_id = matching_draft()
        if release_id is None:
            raise ValueError(f'Created draft for {tag} could not be found')

    # Drafts are addressed by ID because the by-tag API excludes them.
    endpoint = f'{route}/{release_id}'
    draft = json.loads(run(['gh', 'api', endpoint]))
    if draft['id'] != release_id or draft['draft'] is not True or draft['tag_name'] != tag:
        raise ValueError(f'Expected an unpublished draft for {tag}')
    actual = {asset['name']: asset['digest'] for asset in draft['assets']}
    if len(actual) != len(draft['assets']) or actual != expected:
        raise ValueError(f'Draft {release_id} does not match the complete prepared asset set and digests')

    print(run(['gh', 'api', '--method', 'PATCH', endpoint, '-F', 'draft=false',
               '-F', 'prerelease=true', '-f', 'make_latest=false', '--jq', '.html_url']))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory', type=Path)
    args = p.parse_args()
    publish_release(os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_REF_NAME'], args.directory)
