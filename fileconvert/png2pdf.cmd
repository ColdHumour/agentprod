@echo off
setlocal

set "outfile="
set /p "outfile=Output PDF name (default: output.pdf): "
if not defined outfile set "outfile=output.pdf"

python -c "from PIL import Image; import glob,re,os; key=lambda s:[int(x) if x.isdigit() else x.lower() for x in re.split(r'(\d+)',s)]; fs=sorted(glob.glob('*.png'),key=key); assert fs,'No PNG files found'; imgs=[Image.open(f).convert('RGB') for f in fs]; imgs[0].save(os.environ['outfile'],save_all=True,append_images=imgs[1:]); print(f'Created: {os.environ[\"outfile\"]} ({len(imgs)} pages)')"

echo.
pause