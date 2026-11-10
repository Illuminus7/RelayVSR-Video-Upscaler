"""Tags RelayVSR's SDR output as BT.709 video.

ComfyUI's Create Video node labels SDR video with the sRGB transfer function. The upscaled
frames, like the video they come from, are ordinary BT.709 video values, and Apple's players
(QuickTime, Photos, Safari) show a file labelled sRGB about 8 levels darker than the same file
labelled BT.709. That made the upscale look darker and pinker than the original next to it.

This changes only the label written to the file; the pixel values are unchanged. Reading video
is unaffected: ComfyUI already treats BT.709 files as "sRGB".
"""

from av.video.reformatter import ColorTrc
from comfy_api.latest._input_impl import video_types

video_types.VIDEO_COLOR_TRANSFERS["sRGB"] = ColorTrc.BT709

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
