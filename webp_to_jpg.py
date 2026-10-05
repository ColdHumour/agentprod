from pathlib import Path
import sys


def wait_for_key(message):
    print(message, end="", flush=True)
    if sys.platform == "win32" and sys.stdin.isatty():
        import msvcrt

        msvcrt.getch()
        print()
    else:
        input()


try:
    from PIL import Image
except ImportError:
    print("错误：当前 Python 环境未安装 Pillow，无法进行转换。")
    print("请在 Anaconda 环境中安装 Pillow 后再运行。")
    wait_for_key("按任意键退出...")
    sys.exit(1)


def convert_webp_files():
    # 使用脚本文件所在目录，而不是用户启动脚本时所在的当前目录。
    script_dir = Path(__file__).resolve().parent
    webp_files = sorted(
        (
            file_path
            for file_path in script_dir.iterdir()
            if file_path.is_file() and file_path.suffix.lower() == ".webp"
        ),
        key=lambda path: path.name.lower(),
    )

    print(f"扫描目录：{script_dir}")
    print("=" * 60)

    if not webp_files:
        print("没有找到 .webp 文件。")
        return

    success_count = 0
    failure_count = 0

    for source_path in webp_files:
        target_path = source_path.with_suffix(".jpg")
        print(f"正在转换：{source_path.name} -> {target_path.name}", end=" ")

        try:
            with Image.open(source_path) as image:
                # JPEG 不支持透明通道；透明区域用白色填充。
                if image.mode in ("RGBA", "LA") or (
                    image.mode == "P" and "transparency" in image.info
                ):
                    rgba_image = image.convert("RGBA")
                    background = Image.new("RGB", rgba_image.size, "white")
                    background.paste(rgba_image, mask=rgba_image.getchannel("A"))
                    output_image = background
                else:
                    output_image = image.convert("RGB")

                output_image.save(target_path, "JPEG", quality=95)

            print("成功")
            success_count += 1
        except Exception as error:
            print(f"失败：{error}")
            failure_count += 1

    print("=" * 60)
    print(
        f"转换完成：成功 {success_count} 个，失败 {failure_count} 个，"
        f"共找到 {len(webp_files)} 个 .webp 文件。"
    )


if __name__ == "__main__":
    convert_webp_files()
    wait_for_key("\n按任意键退出...")
