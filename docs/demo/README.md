# The demo video

`../hitchhunter-demo.mp4` / `.gif` were made from a real run, not mocked:

1. `capture.py <out.json> <server folder> <console log>` ran on a test server (a copy of a 183-resource server, no
   players, the `hh_trigger` test resource started). It typed each `hhx` command into the server console (a fifo on
   its stdin), ran `pause.sh` for the whole-process test, and timestamped every console line that followed.
   Only the lines of `hh_trigger`, hitchhunter and FXServer's hitch warnings were kept.
2. `capture.json` is that raw record: `[seconds since start, cmd | shell | out, text]`.
3. `render.py capture.json <frames dir>` draws the frames (Pillow; idle gaps over 1.3 s are shortened, nothing else is
   changed), then `ffmpeg -framerate 15 -i <frames>/f_%05d.png -c:v libx264 -pix_fmt yuv420p hitchhunter-demo.mp4`.
