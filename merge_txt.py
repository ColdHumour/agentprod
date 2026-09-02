"""按文件创建时间合并同目录下的 TXT，并在写入前要求用户确认。"""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path


DEFAULT_OUTPUT = "合并结果.txt"


def read_txt(path: Path) -> str:
    """优先按 UTF-8 读取，并兼容常见中文编码。"""
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            return path.read_text(encoding=encoding)
        except UnicodeDecodeError:
            continue
    raise UnicodeError(f"无法识别文件编码：{path.name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"输出文件名（默认：{DEFAULT_OUTPUT}）",
    )
    args = parser.parse_args()

    directory = Path(__file__).resolve().parent
    # 只接受文件名，确保合并结果仍保存在脚本所在目录。
    output_path = directory / Path(args.output).name

    txt_files = [
        path
        for path in directory.glob("*.txt")
        if path.resolve() != output_path.resolve()
    ]
    txt_files.sort(key=lambda path: (path.stat().st_ctime, path.name.casefold()))

    if not txt_files:
        raise SystemExit("同目录下没有可合并的 TXT 文件。")

    print("\n将按以下创建时间顺序合并：")
    for index, path in enumerate(txt_files, start=1):
        created_at = datetime.fromtimestamp(path.stat().st_ctime)
        print(f"{index:>3}. {created_at:%Y-%m-%d %H:%M:%S}  {path.name}")

    print(f"\n共 {len(txt_files)} 个文件")
    print(f"输出文件：{output_path}")
    if output_path.exists():
        print("注意：输出文件已存在，确认后将覆盖它。")

    try:
        answer = input("\n确认按以上顺序合并吗？输入 y 确认，其他输入取消：").strip()
    except (EOFError, KeyboardInterrupt):
        print("\n已取消，未写入任何文件。")
        return

    if answer.lower() not in {"y", "yes"}:
        print("已取消，未写入任何文件。")
        return

    contents = []
    for path in txt_files:
        contents.append(read_txt(path).strip())

    merged_text = "\n\n".join(contents).rstrip() + "\n"
    temporary_path = output_path.with_name(f".{output_path.name}.tmp")
    try:
        temporary_path.write_text(merged_text, encoding="utf-8")
        temporary_path.replace(output_path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()

    print(f"\n合并完成：{output_path}")
    print(f"总字符数：{len(merged_text)}")


if __name__ == "__main__":
    main()
