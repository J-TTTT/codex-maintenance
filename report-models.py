#!/usr/bin/env python3
"""Report target visibility without printing model instruction bodies."""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 5:
        print("用法: report-models.py MODEL BUNDLED REFRESHED CACHE", file=sys.stderr)
        return 2

    target = sys.argv[1]
    paths = [Path(value) for value in sys.argv[2:]]
    labels = ["新版内置目录", "刷新命令结果（可能回退到内置目录）", "实际磁盘缓存"]
    cached = False

    for index, (label, path) in enumerate(zip(labels, paths)):
        try:
            with path.open(encoding="utf-8") as handle:
                data = json.load(handle)
            models = data if isinstance(data, list) else data.get("models")
            if not isinstance(models, list):
                raise ValueError("无法识别目录格式")
            model = next(
                (item for item in models if item.get("slug") == target or item.get("id") == target),
                None,
            )
            print(f"{label}: {'包含' if model else '不包含'} {target}")
            if isinstance(data, dict) and data.get("client_version"):
                print(f"  client_version: {data['client_version']}")
            if isinstance(data, dict) and data.get("fetched_at"):
                print(f"  fetched_at: {data['fetched_at']}")
            if model:
                visibility = model.get("visibility", "未声明")
                levels = model.get("supported_reasoning_levels") or []
                effort = ", ".join(item.get("effort", "") for item in levels)
                print(f"  visibility: {visibility}")
                print(f"  effort: {effort}")
                if index == 2:
                    cached = visibility == "list"
        except FileNotFoundError:
            print(f"{label}: 文件未生成")
        except (OSError, ValueError, json.JSONDecodeError) as error:
            print(f"{label}: {error}")

    if not cached:
        print("尚未确认目标模型进入可见缓存。请检查 refreshed.err 和后台版本；不要反复删除聊天历史。")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
