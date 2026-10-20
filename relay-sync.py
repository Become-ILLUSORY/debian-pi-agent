#!/usr/bin/env python3
"""把第三方中转站（OpenAI/Anthropic 兼容端点）写进 Pi 的 models.json。

- 自动拉取 {baseUrl}/models 作为模型清单（可用 PI_RELAY_MODELS 手写覆盖）
- apiKey 用 "$PI_RELAY_API_KEY" 环境变量插值，密钥不落盘
- 可选把默认模型写进 settings.json（PI_RELAY_DEFAULT_MODEL）

只用标准库，容器内 python3 即可运行。
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


def env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def as_int(name: str, default: int) -> int:
    raw = env(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        print(f"[relay] {name}={raw!r} 不是整数，使用默认值 {default}", file=sys.stderr)
        return default


def as_float(name: str, default: float = 0.0) -> float:
    raw = env(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def fetch_model_ids(base_url: str, api_key: str, api: str, timeout: int = 20) -> list[str]:
    url = base_url.rstrip("/") + "/models"
    headers = {"Accept": "application/json"}
    if api == "anthropic-messages":
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
    else:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8", "replace"))

    items = payload.get("data") if isinstance(payload, dict) else payload
    if items is None and isinstance(payload, dict):
        items = payload.get("models")
    if not isinstance(items, list):
        raise ValueError("响应里没有 data/models 列表")

    ids: list[str] = []
    for item in items:
        if isinstance(item, str):
            ids.append(item)
        elif isinstance(item, dict):
            model_id = item.get("id") or item.get("model") or item.get("name")
            if isinstance(model_id, str) and model_id:
                ids.append(model_id)
    return ids


DEFAULT_EXCLUDE = "embed,embedding,whisper,tts,rerank,moderation,dall-e,gpt-image,stable-diffusion,sdxl,flux,veo,sora,kling,seedream,seedance"


def exclude_ids(ids: list[str], pattern: str) -> list[str]:
    matchers = [p.strip().lower() for p in re.split(r"[,\s]+", pattern) if p.strip()]
    if not matchers:
        return ids

    def hit(model_id: str) -> bool:
        low = model_id.lower()
        return any(m in low for m in matchers)

    return [i for i in ids if not hit(i)]


def apply_filter(ids: list[str], pattern: str | None) -> list[str]:
    if not pattern:
        return ids
    matchers = [p.strip() for p in re.split(r"[,\s]+", pattern) if p.strip()]
    if not matchers:
        return ids

    def hit(model_id: str) -> bool:
        low = model_id.lower()
        for matcher in matchers:
            regex = re.escape(matcher.lower()).replace(r"\*", ".*")
            if re.search(regex, low):
                return True
        return False

    return [i for i in ids if hit(i)]


def main() -> int:
    base_url = env("PI_RELAY_BASE_URL")
    if not base_url:
        return 0  # 没配中转站，什么也不做

    name = env("PI_RELAY_NAME", "relay") or "relay"
    api_key_var = env("PI_RELAY_API_KEY_VAR", "PI_RELAY_API_KEY") or "PI_RELAY_API_KEY"
    api_key = env(api_key_var, "") or ""
    api = env("PI_RELAY_API", "openai-completions") or "openai-completions"
    context_window = as_int("PI_RELAY_CONTEXT_WINDOW", 128000)
    max_tokens = as_int("PI_RELAY_MAX_TOKENS", 16384)
    vision = (env("PI_RELAY_VISION", "0") or "0").lower() in {"1", "true", "yes", "on"}
    sync = (env("PI_RELAY_SYNC", "1") or "1").lower() not in {"0", "false", "no", "off"}
    manual = env("PI_RELAY_MODELS")
    model_filter = env("PI_RELAY_MODEL_FILTER")

    ids: list[str] = []
    if sync:
        if not api_key:
            print(f"[relay] 警告：{api_key_var} 为空，跳过自动拉取模型列表", file=sys.stderr)
        else:
            try:
                ids = fetch_model_ids(base_url, api_key, api)
                print(f"[relay] 从 {base_url.rstrip('/')}/models 拉到 {len(ids)} 个模型")
            except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError) as exc:
                print(f"[relay] 拉取模型列表失败：{exc}", file=sys.stderr)

    if not ids and manual:
        ids = [m.strip() for m in manual.split(",") if m.strip()]
        print(f"[relay] 使用 PI_RELAY_MODELS 指定的 {len(ids)} 个模型")

    if not ids:
        print("[relay] 没有可用的模型清单，models.json 保持不变", file=sys.stderr)
        return 1

    raw_exclude = os.environ.get("PI_RELAY_EXCLUDE")
    exclude = DEFAULT_EXCLUDE if raw_exclude is None else raw_exclude
    ids = sorted(dict.fromkeys(exclude_ids(apply_filter(ids, model_filter), exclude)))
    if not ids:
        print(f"[relay] PI_RELAY_MODEL_FILTER={model_filter!r} 过滤后没有模型", file=sys.stderr)
        return 1

    cost = {
        "input": as_float("PI_RELAY_COST_INPUT"),
        "output": as_float("PI_RELAY_COST_OUTPUT"),
        "cacheRead": as_float("PI_RELAY_COST_CACHE_READ"),
        "cacheWrite": as_float("PI_RELAY_COST_CACHE_WRITE"),
    }
    models = [
        {
            "id": model_id,
            "name": model_id,
            "cost": cost,
            "contextWindow": context_window,
            "maxTokens": max_tokens,
            "input": ["text", "image"] if vision else ["text"],
        }
        for model_id in ids
    ]

    home = Path(os.environ.get("HOME") or "/root")
    agent_dir = Path(env("PI_CODING_AGENT_DIR") or home / ".pi" / "agent")
    agent_dir.mkdir(parents=True, exist_ok=True)

    models_path = agent_dir / "models.json"
    config = {}
    if models_path.exists():
        try:
            config = json.loads(models_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"[relay] {models_path} 解析失败，重写", file=sys.stderr)

    config.setdefault("$schema", "https://pi.dev/schemas/models.schema.json")
    providers = config.setdefault("providers", {})
    providers[name] = {
        "name": env("PI_RELAY_DISPLAY_NAME", name) or name,
        "baseUrl": base_url,
        "api": api,
        "apiKey": f"${api_key_var}",
        "models": models,
    }
    models_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[relay] 已写入 {models_path}（provider={name}, {len(models)} 个模型, api={api}）")

    default_model = env("PI_RELAY_DEFAULT_MODEL")
    if default_model:
        if default_model not in ids:
            print(f"[relay] 警告：默认模型 {default_model} 不在模型清单里", file=sys.stderr)
        settings_path = agent_dir / "settings.json"
        settings = {}
        if settings_path.exists():
            try:
                settings = json.loads(settings_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                settings = {}
        settings["defaultProvider"] = name
        settings["defaultModel"] = default_model
        settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"[relay] 默认模型：{name}/{default_model}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
