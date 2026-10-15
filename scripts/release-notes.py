#!/usr/bin/env python3
"""Render bilingual, versioned image release notes without CI-provider branding."""
import argparse
import json
from pathlib import Path
import re

PROJECT = Path(__file__).resolve().parents[1]
VERSION = r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.(?:0|[1-9][0-9]*))?'


def validate_tag(tag):
    if not re.fullmatch(VERSION, tag):
        raise ValueError('release tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-alpha.N / beta.N / rc.N')
    return tag


def render(tag, repository, commit, inputs_sha256, changes):
    validate_tag(tag)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid repository')
    if not re.fullmatch('[a-f0-9]{40}', commit) or not re.fullmatch('[a-f0-9]{64}', inputs_sha256):
        raise ValueError('release source and binary inputs must be pinned by full hashes')
    sections = [('features', '新增功能', 'New Features'), ('fixes', '问题修复', 'Bug Fixes'),
                ('improvements', '体验优化', 'Improvements'), ('other', '其他变更', 'Other Changes')]
    out = ['[中文](#中文) | [English](#english)', '', '## 中文', '']
    for key, zh, en in sections:
        out += ['### ' + zh, ''] + ['- ' + item['zh'] for item in changes[key]] + ['']
    out += ['### 下载与验证', '',
            '- `server`：Server；`desktop`：GNOME；`desktop-xfce`：XFCE。',
            '- 下载对应 `.img.zst` 和 `.sha256`，先校验 SHA256，再用 `zstd -d` 解压后烧录。',
            '- 完整镜像包含分区和启动组件；烧录会按镜像中的配置初始化目标存储。',
            '- 本版本通过云端构建与打包检查；本批镜像的实机验收尚未完成。历史验收仅适用于原镜像哈希。',
            '- 性能优化与摄像头画质暂缓；原生 ANGLE Vulkan、可选蓝牙及 recovery/OTA 未通过本批验收。',
            '', '### 来源与授权', '',
            '- 软件包基线来自 Ubuntu 软件源；本项目独立维护，不代表 Canonical 官方发行、认证或支持。',
            '- 文档命名调整不代表镜像已完成去标识、商标授权或商业再分发审查。',
            f'- 商业使用与组件许可要求见 [说明](https://github.com/{repository}/blob/{commit}/docs/COMMERCIAL-USE.md)。',
            '', '---', '', '## English', '']
    for key, zh, en in sections:
        out += ['### ' + en, ''] + ['- ' + item['en'] for item in changes[key]] + ['']
    out += ['### Downloads and Validation', '',
            '- `server`: Server; `desktop`: GNOME; `desktop-xfce`: XFCE.',
            '- Download the matching `.img.zst` and `.sha256`, verify SHA256, then decompress with `zstd -d` before flashing.',
            '- Full images include partition and boot components; flashing initializes target storage according to the embedded configuration.',
            '- Cloud build and packaging checks passed. Physical acceptance of this batch is pending; historical results apply only to their original image hashes.',
            '- Performance optimization and camera image quality are deferred. Native ANGLE Vulkan, optional Bluetooth and recovery/OTA are not certified for this batch.',
            '', '### Origin and Licensing', '',
            '- Package baseline: Ubuntu archives. This is an independently maintained project, without a claim of official Canonical distribution, certification or support.',
            '- Documentation naming changes do not certify image debranding, trademark permission or commercial redistribution clearance.',
            f'- See [commercial use and component licensing](https://github.com/{repository}/blob/{commit}/docs/COMMERCIAL-USE.md).',
            '', '### Build Information', '',
            f'- Version: `{tag}`', f'- Source: [{commit[:7]}](https://github.com/{repository}/commit/{commit})',
            f'- Binary inputs SHA256: `{inputs_sha256}`', '']
    return '\n'.join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tag', required=True)
    p.add_argument('--repository')
    p.add_argument('--commit')
    p.add_argument('--inputs-sha256')
    p.add_argument('--output', type=Path)
    p.add_argument('--validate-only', action='store_true')
    a = p.parse_args()
    validate_tag(a.tag)
    if a.validate_only:
        return
    if not all([a.repository, a.commit, a.inputs_sha256, a.output]):
        p.error('rendering requires --repository, --commit, --inputs-sha256 and --output')
    changes = json.loads((PROJECT / 'config/release/notes.json').read_text())
    a.output.write_text(render(a.tag, a.repository, a.commit, a.inputs_sha256, changes))


if __name__ == '__main__':
    main()
