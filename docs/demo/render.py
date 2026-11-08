import sys,subprocess,os,shutil
from playwright.sync_api import sync_playwright
out=os.path.dirname(os.path.abspath(__file__)); FPS=12
with sync_playwright() as p:
    b=p.chromium.launch(channel='chrome'); pg=b.new_page(viewport={'width':880,'height':500}); pg.goto('file://'+out+'/demo.html')
    for n in ['dictate','ask','history','models']:
        d=pg.evaluate(f'dur("{n}")'); fr=f'/tmp/fr_{n}'; shutil.rmtree(fr,ignore_errors=True); os.makedirs(fr)
        for i in range(int(d*FPS)):
            pg.evaluate(f'seek("{n}",{i/FPS})'); pg.screenshot(path=f'{fr}/{i:04d}.png')
        subprocess.run(['ffmpeg','-y','-loglevel','error','-framerate',str(FPS),'-i',f'{fr}/%04d.png','-vf','split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer:bayer_scale=4','-loop','0',f'{out}/{n}.gif'])
    b.close()
